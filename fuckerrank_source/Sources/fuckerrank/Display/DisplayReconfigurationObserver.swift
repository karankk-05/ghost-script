import AppKit
import CoreGraphics

struct DisplayChange {
    let id: CGDirectDisplayID
    let flags: CGDisplayChangeSummaryFlags
}

/// One debounced batch of reconfiguration events. `selfInflicted` marks
/// batches caused by our own CGCompleteDisplayConfiguration transactions so
/// the mirror state machine never reacts to itself.
struct DisplayChangeSet {
    let changes: [DisplayChange]
    let selfInflicted: Bool

    private func any(_ flag: CGDisplayChangeSummaryFlags) -> Bool {
        changes.contains { $0.flags.contains(flag) }
    }
    var added: Bool { any(.addFlag) || any(.enabledFlag) }
    var removed: Bool { any(.removeFlag) || any(.disabledFlag) }
    var mirrored: Bool { any(.mirrorFlag) }
    var unmirrored: Bool { any(.unMirrorFlag) }
    var reshaped: Bool { any(.movedFlag) || any(.setModeFlag) || any(.desktopShapeChangedFlag) }
    func involves(_ id: CGDirectDisplayID) -> Bool { changes.contains { $0.id == id } }
}

/// CoreGraphics reconfiguration callback → 500 ms debounced DisplayChangeSet
/// on the MainActor. The CG callback fires synchronously (begin + after
/// phases, per display) on the thread completing the transaction; we drop the
/// begin phase and coalesce the rest.
@MainActor
final class DisplayReconfigurationObserver {
    var onChange: ((DisplayChangeSet) -> Void)?

    /// Set by MirrorConfigurator around its own transactions. Because the CG
    /// callback fires synchronously inside CGCompleteDisplayConfiguration,
    /// reading this from the callback correctly tags our own events.
    var isSuppressed = false

    private var pending: [DisplayChange] = []
    private var pendingSelfInflicted = false
    private var debounceTask: Task<Void, Never>?

    init() {
        CGDisplayRegisterReconfigurationCallback(Self.trampoline,
                                                 Unmanaged.passUnretained(self).toOpaque())
    }
    // App-lifetime object (owned by AppDelegate); no deregistration needed.

    private static let trampoline: CGDisplayReconfigurationCallBack = { id, flags, userInfo in
        guard let userInfo else { return }
        let observer = Unmanaged<DisplayReconfigurationObserver>.fromOpaque(userInfo).takeUnretainedValue()
        if Thread.isMainThread {
            MainActor.assumeIsolated { observer.record(id: id, flags: flags) }
        } else {
            Task { @MainActor in observer.record(id: id, flags: flags) }
        }
    }

    private func record(id: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        guard !flags.contains(.beginConfigurationFlag) else { return }
        pending.append(DisplayChange(id: id, flags: flags))
        pendingSelfInflicted = pendingSelfInflicted || isSuppressed
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.deliver()
        }
    }

    private func deliver() {
        guard !pending.isEmpty else { return }
        let batch = DisplayChangeSet(changes: pending, selfInflicted: pendingSelfInflicted)
        pending = []
        pendingSelfInflicted = false
        onChange?(batch)
    }
}
