import Foundation

/// What was mirrored before we broke it, keyed by stable display UUIDs.
struct MirrorSnapshot: Codable {
    struct Pair: Codable {
        let secondaryUUID: UUID
        let masterUUID: UUID
    }
    let pairs: [Pair]
    let bootTime: TimeInterval
    let createdAt: Date
}

/// Crash marker in UserDefaults. Saved BEFORE CGCompleteDisplayConfiguration
/// commits the break, cleared after a successful restore — so if it exists at
/// launch, a previous session died while the displays were extended.
/// `.forSession` scope means a reboot reverts the config anyway, hence the
/// boot-time validation.
struct MirrorSnapshotStore {
    private static let key = "mirrorSnapshotMarker"

    static func currentBootTime() -> TimeInterval {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
        return TimeInterval(tv.tv_sec)
    }

    func save(_ snapshot: MirrorSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// The marker, but only if it was written during the current boot.
    func loadValidForThisBoot() -> MirrorSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let snapshot = try? JSONDecoder().decode(MirrorSnapshot.self, from: data) else {
            return nil
        }
        guard abs(snapshot.bootTime - Self.currentBootTime()) < 5 else {
            clear() // stale — a reboot already reverted the session config
            return nil
        }
        return snapshot
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}
