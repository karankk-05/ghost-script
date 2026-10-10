import AppKit
import ColorSync
import CoreGraphics

/// Enumerates displays via CGGetOnlineDisplayList (which, unlike the active
/// list and NSScreen, still includes hardware-mirror secondaries) and keeps
/// AppState.topology fresh.
@MainActor
final class DisplayManager {
    private let state: AppState

    init(state: AppState) {
        self.state = state
    }

    func refresh() {
        state.topology = Self.currentTopology()
    }

    static func currentTopology() -> DisplayTopology {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: max(Int(count), 16))
        CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)

        let displays = ids.prefix(Int(count)).map { id -> DisplayInfo in
            let mode = CGDisplayCopyDisplayMode(id)
            let isBuiltin = CGDisplayIsBuiltin(id) != 0
            let name = NSScreen.screen(for: id)?.localizedName
                ?? (isBuiltin ? "Built-in Display" : "Display \(id)")
            return DisplayInfo(
                id: id,
                uuid: uuid(for: id),
                isBuiltin: isBuiltin,
                isMain: CGDisplayIsMain(id) != 0,
                isActive: CGDisplayIsActive(id) != 0,
                mirrorsDisplay: CGDisplayMirrorsDisplay(id),
                isAlwaysInMirrorSet: CGDisplayIsAlwaysInMirrorSet(id) != 0,
                boundsPts: CGDisplayBounds(id),
                pixelWidth: mode?.pixelWidth ?? Int(CGDisplayPixelsWide(id)),
                pixelHeight: mode?.pixelHeight ?? Int(CGDisplayPixelsHigh(id)),
                name: name)
        }
        return DisplayTopology(displays: Array(displays))
    }

    /// Beamer target policy: the user's pick if it's online, else the first
    /// active external, else any external (a mirror secondary is inactive
    /// but still a valid target — we unmirror it first).
    static func preferredExternal(in topology: DisplayTopology, selectedUUID: UUID?) -> DisplayInfo? {
        if let selectedUUID, let chosen = topology.display(uuid: selectedUUID), !chosen.isBuiltin {
            return chosen
        }
        return topology.externals.first { $0.isActive } ?? topology.externals.first
    }

    // MARK: - UUID mapping (ColorSync); IDs are not stable across replug/reboot

    static func uuid(for id: CGDirectDisplayID) -> UUID? {
        guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return UUID(uuidString: CFUUIDCreateString(nil, cf) as String)
    }

    static func displayID(for uuid: UUID) -> CGDirectDisplayID? {
        guard let cf = CFUUIDCreateFromString(nil, uuid.uuidString as CFString) else { return nil }
        let id = CGDisplayGetDisplayIDFromUUID(cf)
        return id == 0 ? nil : id
    }
}
