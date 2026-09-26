import CoreGraphics
import Foundation

/// Immutable snapshot of one online display. IDs are session-unstable;
/// anything persisted is keyed by `uuid` instead.
struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let uuid: UUID?
    let isBuiltin: Bool
    let isMain: Bool
    /// Hardware-mirror secondaries are online but NOT active (not drawable).
    let isActive: Bool
    /// Display this one mirrors; 0 (kCGNullDirectDisplay) when not a mirror secondary.
    let mirrorsDisplay: CGDirectDisplayID
    let isAlwaysInMirrorSet: Bool
    let boundsPts: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let name: String

    var isMirrorSecondary: Bool { mirrorsDisplay != 0 }
}

struct DisplayTopology: Equatable {
    let displays: [DisplayInfo]

    var builtin: DisplayInfo? { displays.first { $0.isBuiltin } }
    var externals: [DisplayInfo] { displays.filter { !$0.isBuiltin } }
    var isMirroring: Bool { displays.contains { $0.isMirrorSecondary } }
    var mirrorSecondaries: [DisplayInfo] { displays.filter { $0.isMirrorSecondary } }

    func display(id: CGDirectDisplayID) -> DisplayInfo? {
        displays.first { $0.id == id }
    }
    func display(uuid: UUID) -> DisplayInfo? {
        displays.first { $0.uuid == uuid }
    }
}
