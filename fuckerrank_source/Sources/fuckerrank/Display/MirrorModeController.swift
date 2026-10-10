import AppKit

/// UI projection of the mirror session.
enum MirrorStatus: Equatable {
    case off
    case starting(String)          // phase description
    case active(fps: Double)
    case suspended(String)         // target display vanished; auto-resumes
    case stoppedBySystem(String)   // user/system hit "Stop sharing" → Resume button
    case failed(String)
}

/// The beamer mirror session: state machine and per-session composition root.
///
/// Start: TCC preflight (BEFORE any display mutation) → break OS mirroring
/// (.forSession, marker saved first) → wait for the external's NSScreen to
/// materialize → output window up → capture start → active.
/// Stop: capture → window → re-mirror → clear marker. Never the other order:
/// re-mirroring kills the external's NSScreen out from under the window.
///
/// Concurrency model: everything is MainActor, but transitions await (capture
/// start/stop, screen polling), so they interleave at suspension points. Two
/// mechanisms keep them coherent:
/// - `generation` is bumped by every user-intent change (start/stop/terminal
///   failure); spawned reactions capture it and re-check after EVERY await,
///   bailing silently when stale.
/// - `currentTransition` serializes transitions: each new one first awaits
///   the previous, and teardown paths run unconditionally afterwards.
@MainActor
final class MirrorModeController {
    private let state: AppState
    private let permission: CapturePermission
    private let configurator: MirrorConfigurator
    private let renderer: BeamerRenderer
    private let output = BeamerOutputWindowController()
    /// The notes overlay's window number — excluded belt-and-braces (it is
    /// already compositor-excluded via sharingType = .none).
    private let overlayWindowNumber: () -> Int

    private struct SessionContext {
        var builtinID: CGDirectDisplayID
        var targetUUID: UUID
        var outputPixelSize: CGSize
        var maxHz: Int
    }
    private var session: SessionContext?
    private var generation = 0
    private var currentTransition: Task<Void, Never>?
    private var remirrorEvents: [Date] = []

    var isActive: Bool {
        switch state.mirrorStatus {
        case .off, .failed: return false
        default: return true
        }
    }

    init(state: AppState,
         permission: CapturePermission,
         configurator: MirrorConfigurator,
         renderer: BeamerRenderer,
         overlayWindowNumber: @escaping () -> Int) {
        self.state = state
        self.permission = permission
        self.configurator = configurator
        self.renderer = renderer
        self.overlayWindowNumber = overlayWindowNumber

        renderer.onStats = { [weak self] stats in
            guard let self, case .active = self.state.mirrorStatus else { return }
            self.state.mirrorStatus = .active(fps: stats.fps)
            self.state.mirrorDegraded = stats.looksStalled
        }
        renderer.onFailure = { [weak self] failure in
            self?.handleCaptureFailure(failure)
        }
    }

    private func valid(_ gen: Int) -> Bool { generation == gen }

    // MARK: - Start / stop (user intent)

    func start() async {
        await currentTransition?.value // let any in-flight transition settle
        guard !isActive else { return }
        generation += 1
        let gen = generation
        remirrorEvents = []
        state.mirrorError = nil
        let task = Task { await self.performStart(gen) }
        currentTransition = task
        await task.value
    }

    func stop() async {
        generation += 1 // immediately invalidates every spawned reaction
        await currentTransition?.value
        let task = Task { await self.teardown(finalStatus: .off) }
        currentTransition = task
        await task.value
    }

    /// After a user/system "Stop sharing": window and arrangement are still
    /// up — only the stream needs restarting. Registered as the current
    /// transition so a concurrent Stop waits for it instead of racing it.
    func resumeCapture() async {
        await currentTransition?.value
        guard case .stoppedBySystem = state.mirrorStatus, session != nil else { return }
        generation += 1
        let gen = generation
        let task = Task { await self.performResumeCapture(gen) }
        currentTransition = task
        await task.value
    }

    private func performResumeCapture(_ gen: Int) async {
        guard let context = session else { return }
        state.mirrorStatus = .starting("Resuming the mirror stream…")
        do {
            try await renderer.start(capturingDisplay: context.builtinID,
                                     excludingWindowNumbers: excludedWindowNumbers(),
                                     outputPixelSize: context.outputPixelSize,
                                     outputMaxHz: context.maxHz)
            guard valid(gen) else { return }
            state.mirrorStatus = .active(fps: 0)
        } catch {
            guard valid(gen) else { return }
            failTerminally("Could not resume: \(error.localizedDescription)")
        }
    }

    /// Clean shutdown for app termination: also restores the arrangement when
    /// a failure path left mirroring broken without an active session.
    func shutdown() async {
        generation += 1
        await currentTransition?.value
        if isActive || configurator.weBrokeMirroring {
            await teardown(finalStatus: .off)
        }
    }

    // MARK: - The start sequence

    private func performStart(_ gen: Int) async {
        GSLog.log("start: begin (gen \(gen))")
        // 1. Permission BEFORE any display mutation.
        state.mirrorStatus = .starting("Checking screen-recording permission…")
        let permissionResult = await permission.probe()
        GSLog.log("start: permission probe = \(permissionResult)")
        guard valid(gen) else { return }
        guard permissionResult == .granted else {
            state.permissionState = .denied
            permission.request() // surfaces the system prompt on first refusal
            state.mirrorStatus = .failed(
                "Screen Recording permission is required. Grant it in System Settings, then relaunch fuckerrank.")
            return
        }
        state.permissionState = .granted

        // 2. Displays present?
        var topology = DisplayManager.currentTopology()
        guard topology.builtin != nil else {
            state.mirrorStatus = .failed("No built-in display (clamshell mode?) — nothing to mirror from.")
            return
        }
        guard let target = DisplayManager.preferredExternal(in: topology,
                                                            selectedUUID: state.selectedExternalUUID),
              let targetUUID = target.uuid else {
            state.mirrorStatus = .failed("No external display connected.")
            return
        }

        // 3. Break OS mirroring if present (no-op on an extended setup).
        if topology.isMirroring {
            state.mirrorStatus = .starting("Switching displays to extended…")
            GSLog.log("start: breaking OS mirroring")
            do {
                try configurator.breakMirroring()
            } catch {
                GSLog.log("start: breakMirroring FAILED: \(error.localizedDescription)")
                state.mirrorStatus = .failed(error.localizedDescription)
                return
            }
        }

        // 4. Wait for the external's NSScreen (materializes asynchronously).
        state.mirrorStatus = .starting("Waiting for the external display…")
        guard let screen = await waitForScreen(uuid: targetUUID) else {
            guard valid(gen) else { return }
            await rollbackMirroringIfNeeded()
            state.mirrorStatus = .failed("The external display never became usable — display arrangement was restored.")
            return
        }
        guard valid(gen) else { return }

        // Fresh topology: IDs and pixel sizes (built-in included) can change
        // across the break.
        topology = DisplayManager.currentTopology()
        guard let freshBuiltin = topology.builtin,
              let freshTarget = topology.display(uuid: targetUUID) else {
            await rollbackMirroringIfNeeded()
            state.mirrorStatus = .failed("Lost track of a display after reconfiguration — arrangement restored.")
            return
        }
        let context = SessionContext(
            builtinID: freshBuiltin.id,
            targetUUID: targetUUID,
            outputPixelSize: state.nativeSourceCapture
                ? .zero // builder treats zero as "capture at native source size"
                : CGSize(width: freshTarget.pixelWidth, height: freshTarget.pixelHeight),
            maxHz: Int(screen.maximumFramesPerSecond))
        session = context

        // 5. Window up BEFORE capture start (its number joins the filter).
        output.show(on: screen, hosting: renderer.makeOutputView())

        // 6. Capture.
        state.mirrorStatus = .starting("Starting the mirror stream…")
        GSLog.log("start: capture from display \(context.builtinID), output \(context.outputPixelSize), \(context.maxHz)Hz")
        do {
            try await renderer.start(capturingDisplay: context.builtinID,
                                     excludingWindowNumbers: excludedWindowNumbers(),
                                     outputPixelSize: context.outputPixelSize,
                                     outputMaxHz: context.maxHz)
        } catch {
            GSLog.log("start: capture start FAILED: \(error.localizedDescription)")
            guard valid(gen) else { return } // an intervening stop() owns cleanup
            await teardown(finalStatus: .failed("Mirror stream failed to start: \(error.localizedDescription)"))
            return
        }
        guard valid(gen) else { return }
        GSLog.log("start: ACTIVE")
        state.mirrorDegraded = false
        state.mirrorStatus = .active(fps: 0)
    }

    // MARK: - Teardown (single unconditional path)

    /// Capture → window → re-mirror, in that order, always all three.
    private func teardown(finalStatus: MirrorStatus) async {
        GSLog.log("teardown → \(finalStatus)")
        await renderer.stop()
        output.close()
        await rollbackMirroringIfNeeded()
        session = nil
        remirrorEvents = []
        state.mirrorDegraded = false
        state.mirrorStatus = finalStatus
    }

    /// Terminal failure with full cleanup, serialized behind any in-flight
    /// transition. Bumps the generation so stale reactions die.
    private func failTerminally(_ message: String) {
        generation += 1
        let previous = currentTransition
        currentTransition = Task { [weak self] in
            await previous?.value
            await self?.teardown(finalStatus: .failed(message))
        }
    }

    // MARK: - Hotplug / reconfiguration policy

    func handle(_ changeSet: DisplayChangeSet) {
        guard !changeSet.selfInflicted, let context = session else { return }
        let topology = DisplayManager.currentTopology()

        switch state.mirrorStatus {
        case .active, .stoppedBySystem, .starting:
            if topology.builtin == nil {
                failTerminally("Built-in display disappeared — mirror stopped.")
                return
            }
            if topology.display(uuid: context.targetUUID) == nil {
                enqueueReaction { gen in
                    await self.renderer.stop()
                    guard self.valid(gen) else { return }
                    self.output.close()
                    self.state.mirrorStatus = .suspended("The external display was disconnected — waiting for it to return…")
                }
                return
            }
            if changeSet.mirrored && topology.isMirroring {
                handleOSRemirror()
                return
            }
            if changeSet.reshaped {
                enqueueReaction { gen in await self.refit(gen) }
            }
        case .suspended:
            if changeSet.added || changeSet.unmirrored,
               topology.display(uuid: context.targetUUID) != nil {
                enqueueReaction { gen in await self.resumeFromSuspension(gen) }
            }
        default:
            break
        }
    }

    /// Reactions serialize behind the current transition and die silently if
    /// the user's intent changed (generation bump) while they waited.
    private func enqueueReaction(_ body: @escaping (_ gen: Int) async -> Void) {
        let gen = generation
        let previous = currentTransition
        currentTransition = Task { [weak self] in
            await previous?.value
            guard let self, self.valid(gen) else { return }
            await body(gen)
        }
    }

    private func handleOSRemirror() {
        let now = Date()
        remirrorEvents = remirrorEvents.filter { now.timeIntervalSince($0) < 30 } + [now]
        guard remirrorEvents.count < 2 else {
            failTerminally("macOS keeps re-enabling mirroring (twice in 30 s) — mirror stopped instead of fighting it.")
            return
        }
        enqueueReaction { gen in
            do {
                try self.configurator.breakMirroring()
            } catch {
                guard self.valid(gen) else { return }
                self.failTerminally("Could not re-break mirroring: \(error.localizedDescription)")
            }
        }
    }

    private func resumeFromSuspension(_ gen: Int) async {
        guard var context = session else { return }
        state.mirrorStatus = .starting("Display returned — resuming…")
        // Replug often re-establishes mirroring; break it again if so.
        if DisplayManager.currentTopology().isMirroring {
            _ = try? configurator.breakMirroring()
        }
        guard let screen = await waitForScreen(uuid: context.targetUUID) else {
            guard valid(gen) else { return }
            state.mirrorStatus = .suspended("The external display did not become usable — still waiting…")
            return
        }
        guard valid(gen) else { return }
        // Both displays may have new IDs after the replug/re-break.
        let topology = DisplayManager.currentTopology()
        if let freshBuiltin = topology.builtin {
            context.builtinID = freshBuiltin.id
            session = context
        }
        output.show(on: screen, hosting: renderer.makeOutputView())
        do {
            try await renderer.start(capturingDisplay: context.builtinID,
                                     excludingWindowNumbers: excludedWindowNumbers(),
                                     outputPixelSize: context.outputPixelSize,
                                     outputMaxHz: context.maxHz)
            guard valid(gen) else { return }
            state.mirrorStatus = .active(fps: 0)
        } catch {
            guard valid(gen) else { return }
            failTerminally("Resume failed: \(error.localizedDescription)")
        }
    }

    private func refit(_ gen: Int) async {
        guard let context = session,
              let id = DisplayManager.displayID(for: context.targetUUID),
              let screen = NSScreen.screen(for: id) else { return }
        output.refit(to: screen)
        let topology = DisplayManager.currentTopology()
        if let fresh = topology.display(uuid: context.targetUUID) {
            var updated = context
            updated.outputPixelSize = state.nativeSourceCapture
                ? .zero
                : CGSize(width: fresh.pixelWidth, height: fresh.pixelHeight)
            updated.maxHz = Int(screen.maximumFramesPerSecond)
            session = updated
            await renderer.updateOutput(pixelSize: updated.outputPixelSize, maxHz: updated.maxHz)
        }
    }

    // MARK: - Helpers

    private func handleCaptureFailure(_ failure: CaptureFailure) {
        switch failure {
        case .stopped(let reason):
            state.mirrorStatus = .stoppedBySystem(reason)
        case .permissionDenied:
            state.permissionState = .denied
            failTerminally("Screen Recording permission was revoked — grant it and relaunch.")
        case .failed(let message):
            failTerminally("Mirror stream failed: \(message)")
        }
    }

    private func rollbackMirroringIfNeeded() async {
        guard configurator.weBrokeMirroring,
              let snapshot = configurator.pendingCrashSnapshot() else { return }
        do {
            try configurator.restore(snapshot)
        } catch {
            state.mirrorError = "Could not restore mirroring: \(error.localizedDescription)"
        }
    }

    private func excludedWindowNumbers() -> [Int] {
        var numbers = [overlayWindowNumber()]
        if let beamer = output.windowNumber {
            numbers.append(beamer)
        }
        return numbers
    }

    /// Poll for the target's NSScreen — IDs can change across the mirror
    /// break, so resolution goes through the UUID every time.
    private func waitForScreen(uuid: UUID, timeout: TimeInterval = 5) async -> NSScreen? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let id = DisplayManager.displayID(for: uuid),
               let screen = NSScreen.screen(for: id) {
                return screen
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }
}
