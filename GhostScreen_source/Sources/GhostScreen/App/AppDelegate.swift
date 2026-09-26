import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private(set) lazy var documents = DocumentController(state: state)
    private(set) lazy var overlay = OverlayWindowController(state: state, documents: documents)
    private(set) lazy var indicator = IndicatorWindowController()
    private(set) lazy var promptWindow = PromptWindowController()
    private(set) lazy var displayManager = DisplayManager(state: state)
    private(set) lazy var reconfigObserver = DisplayReconfigurationObserver()
    private(set) lazy var mirrorConfigurator = MirrorConfigurator(observer: reconfigObserver)
    private(set) lazy var capturePermission = CapturePermission()
    
    var settingsWindow: NSWindow?
    private(set) lazy var mirrorController = MirrorModeController(
        state: state,
        permission: capturePermission,
        configurator: mirrorConfigurator,
        renderer: CapturePipeline(),
        overlayWindowNumber: { [weak self] in self?.overlay.panel.windowNumber ?? 0 })

    /// Crash marker found at launch, held until the user decides.
    private var crashSnapshot: MirrorSnapshot?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        GSLog.log("launched — bundled=\(state.isBundled) preflight=\(capturePermission.preflight())")
        statusItemController = StatusItemController(state: state, appDelegate: self)
        overlay.bind()

        displayManager.refresh()
        reconfigObserver.onChange = { [weak self] changeSet in
            self?.displayManager.refresh()
            self?.mirrorController.handle(changeSet)
        }
        // Validate a previously granted permission without ever triggering
        // the system prompt at launch.
        if capturePermission.preflight() {
            Task { @MainActor in
                state.permissionState = await capturePermission.probe()
            }
        }
        if let snapshot = mirrorConfigurator.pendingCrashSnapshot() {
            crashSnapshot = snapshot
            state.restoreOfferPairCount = snapshot.pairs.count
        }

        if ProcessInfo.processInfo.environment["GHOSTSCREEN_AUTOTEST_CAPTURE"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.toggleTestCapture()
            }
        }
    }

    // MARK: - Dev test capture (M3 verification: pipeline into a plain window)

    private var testCapture: CapturePipeline?
    private var testWindow: NSWindow?

    func toggleTestCapture() {
        if testCapture != nil {
            stopTestCapture()
            return
        }
        guard let builtin = state.topology.builtin else {
            state.mirrorError = "No built-in display found for test capture."
            return
        }
        let pipeline = CapturePipeline()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 60, width: 640, height: 400),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Test Capture — starting…"
        window.isReleasedWhenClosed = false
        window.contentView = pipeline.makeOutputView()
        window.orderFrontRegardless()

        pipeline.onStats = { [weak window] stats in
            window?.title = String(format: "Test Capture — %.0f fps, drop %d, idle %d%@",
                                   stats.fps, stats.droppedFrames, stats.idleFrames,
                                   stats.looksStalled ? ", STALLED" : "")
        }
        pipeline.onFailure = { [weak self] failure in
            self?.state.mirrorError = "Test capture: \(failure)"
        }
        testCapture = pipeline
        testWindow = window

        Task { @MainActor in
            do {
                try await pipeline.start(
                    capturingDisplay: builtin.id,
                    excludingWindowNumbers: [overlay.panel.windowNumber, window.windowNumber],
                    outputPixelSize: CGSize(width: 1280, height: 800),
                    outputMaxHz: 60)
            } catch {
                state.mirrorError = "Test capture failed: \(error.localizedDescription)"
                stopTestCapture()
            }
        }
    }

    private func stopTestCapture() {
        let pipeline = testCapture
        testCapture = nil
        testWindow?.orderOut(nil)
        testWindow = nil
        Task { @MainActor in
            await pipeline?.stop()
        }
    }

    // MARK: - Crash-marker restore banner

    func acceptRestoreOffer() {
        guard !mirrorController.isActive else {
            state.mirrorError = "Stop the beamer mirror before restoring the previous display arrangement."
            return
        }
        guard let snapshot = crashSnapshot else { return }
        do {
            try mirrorConfigurator.restore(snapshot)
            crashSnapshot = nil
            state.restoreOfferPairCount = 0
            state.mirrorError = nil
        } catch {
            state.mirrorError = error.localizedDescription
        }
    }

    func dismissRestoreOffer() {
        // Once a live session has written its own marker, the UserDefaults
        // entry belongs to that session — only its restore may clear it.
        if !mirrorConfigurator.weBrokeMirroring {
            mirrorConfigurator.store.clear()
        }
        crashSnapshot = nil
        state.restoreOfferPairCount = 0
    }

    /// Dock drops and Finder "Open With" arrive here (CFBundleDocumentTypes).
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        GSLog.log("openFile: \(filename)")
        let url = URL(fileURLWithPath: filename)
        let exts = ["md", "markdown", "mdown", "txt"]
        if exts.contains(url.pathExtension.lowercased()) {
            documents.open(url: url)
            state.overlayVisible = true
            GSLog.log("openFile SUCCESS")
            return true
        }
        return false
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        GSLog.log("open urls: \(urls)")
        if let url = urls.first(where: { $0.scheme == "ghostscreen" }) {
            GSLog.log("ghostscreen url: \(url)")
            if url.host == "theme" {
                state.theme = url.lastPathComponent
                promptWindow.setTheme(url.lastPathComponent)
            } else if url.host == "indicator" {
                indicator.setIndicator(color: url.lastPathComponent)
            } else if url.host == "prompt" {
                promptWindow.toggle()
            }
            return
        }
        
        let exts = ["md", "markdown", "mdown", "txt"]
        if let url = urls.first(where: { exts.contains($0.pathExtension.lowercased()) }) {
            documents.open(url: url)
            state.overlayVisible = true
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // the overlay may still be presenting
    }

    /// Never quit with the displays left extended: stop capture, close the
    /// beamer window, restore mirroring, then terminate. weBrokeMirroring
    /// covers failure states that are no longer "active" but still left the
    /// arrangement broken.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard mirrorController.isActive || mirrorConfigurator.weBrokeMirroring else {
            return .terminateNow
        }
        Task { @MainActor in
            await mirrorController.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func toggleOverlay() {
        state.overlayVisible.toggle()
    }
}
