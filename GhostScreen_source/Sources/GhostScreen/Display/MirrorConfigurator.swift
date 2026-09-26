import ColorSync
import CoreGraphics
import Foundation

enum MirrorConfigError: LocalizedError {
    case beginFailed(CGError)
    case configureFailed(CGError)
    case completeFailed(CGError)
    case alwaysMirrored
    case missingUUID(CGDirectDisplayID)
    case displaysGone

    var errorDescription: String? {
        switch self {
        case .beginFailed(let e):
            return "Could not start a display configuration transaction (CGError \(e.rawValue))."
        case .configureFailed(let e):
            return "Display configuration was rejected (CGError \(e.rawValue))."
        case .completeFailed(let e):
            return "Applying the display configuration failed (CGError \(e.rawValue)). "
                + "If a presentation app is in fullscreen, exit fullscreen, start the mirror, then re-enter fullscreen."
        case .alwaysMirrored:
            return "This display is permanently mirrored by the system (AirPlay/Sidecar) and can't be unmirrored."
        case .missingUUID(let id):
            return "Display \(id) has no stable identifier; refusing to change its configuration."
        case .displaysGone:
            return "The previously mirrored displays are no longer connected."
        }
    }
}

/// Breaks and restores OS display mirroring in single `.forSession`
/// transactions. `.forSession` is deliberate: even after a crash, logout or
/// reboot reverts everything; the marker + launch banner handles the
/// crash-within-session case.
@MainActor
final class MirrorConfigurator {
    private let observer: DisplayReconfigurationObserver
    let store = MirrorSnapshotStore()
    private(set) var weBrokeMirroring = false

    init(observer: DisplayReconfigurationObserver) {
        self.observer = observer
    }

    func pendingCrashSnapshot() -> MirrorSnapshot? {
        store.loadValidForThisBoot()
    }

    /// Unmirror every mirrored pair. Returns nil (and changes nothing) when
    /// nothing is mirrored — mirror mode then proceeds on the existing
    /// extended arrangement with `weBrokeMirroring == false`.
    @discardableResult
    func breakMirroring() throws -> MirrorSnapshot? {
        let topology = DisplayManager.currentTopology()
        let secondaries = topology.mirrorSecondaries
        guard !secondaries.isEmpty else { return nil }
        guard !secondaries.contains(where: { $0.isAlwaysInMirrorSet }) else {
            throw MirrorConfigError.alwaysMirrored
        }

        var pairs: [MirrorSnapshot.Pair] = []
        for d in secondaries {
            guard let sUUID = d.uuid,
                  let mUUID = DisplayManager.uuid(for: d.mirrorsDisplay) else {
                throw MirrorConfigError.missingUUID(d.id)
            }
            pairs.append(.init(secondaryUUID: sUUID, masterUUID: mUUID))
        }
        let snapshot = MirrorSnapshot(pairs: pairs,
                                      bootTime: MirrorSnapshotStore.currentBootTime(),
                                      createdAt: Date())

        var cfgOpt: CGDisplayConfigRef?
        let beginErr = CGBeginDisplayConfiguration(&cfgOpt)
        guard beginErr == .success, let cfg = cfgOpt else {
            throw MirrorConfigError.beginFailed(beginErr)
        }
        for d in secondaries {
            let err = CGConfigureDisplayMirrorOfDisplay(cfg, d.id, kCGNullDirectDisplay)
            guard err == .success else {
                CGCancelDisplayConfiguration(cfg) // token dead after cancel
                throw MirrorConfigError.configureFailed(err)
            }
        }

        store.save(snapshot) // marker BEFORE complete — crash safety
        observer.isSuppressed = true
        defer { observer.isSuppressed = false }
        let completeErr = CGCompleteDisplayConfiguration(cfg, .forSession)
        guard completeErr == .success else {
            // Complete consumes the token even on failure — do NOT cancel.
            store.clear() // nothing changed; marker would be a lie
            throw MirrorConfigError.completeFailed(completeErr)
        }
        weBrokeMirroring = true
        return snapshot
    }

    /// Re-mirror the pairs from a snapshot. Displays that are gone are
    /// skipped; the marker stays put if applying fails so the user can retry.
    func restore(_ snapshot: MirrorSnapshot) throws {
        let resolved: [(secondary: CGDirectDisplayID, master: CGDirectDisplayID)] =
            snapshot.pairs.compactMap { pair in
                guard let s = DisplayManager.displayID(for: pair.secondaryUUID),
                      let m = DisplayManager.displayID(for: pair.masterUUID) else { return nil }
                return (s, m)
            }
        guard !resolved.isEmpty else {
            store.clear()
            weBrokeMirroring = false
            throw MirrorConfigError.displaysGone
        }

        var cfgOpt: CGDisplayConfigRef?
        let beginErr = CGBeginDisplayConfiguration(&cfgOpt)
        guard beginErr == .success, let cfg = cfgOpt else {
            throw MirrorConfigError.beginFailed(beginErr)
        }
        for (s, m) in resolved {
            let err = CGConfigureDisplayMirrorOfDisplay(cfg, s, m)
            guard err == .success else {
                CGCancelDisplayConfiguration(cfg)
                throw MirrorConfigError.configureFailed(err)
            }
        }
        observer.isSuppressed = true
        defer { observer.isSuppressed = false }
        let completeErr = CGCompleteDisplayConfiguration(cfg, .forSession)
        guard completeErr == .success else {
            throw MirrorConfigError.completeFailed(completeErr) // marker kept for retry
        }
        store.clear()
        weBrokeMirroring = false
    }

    /// Nuclear option behind an explicit menu item only.
    func panicRestore() {
        CGRestorePermanentDisplayConfiguration()
        store.clear()
        weBrokeMirroring = false
    }
}
