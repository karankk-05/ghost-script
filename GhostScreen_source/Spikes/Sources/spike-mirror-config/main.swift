// Spike B — can we programmatically break and restore OS display mirroring
// on this machine (Apple Silicon, macOS 26)?
//
//   spike-mirror-config status          list online displays + mirror relationships
//   spike-mirror-config break           unmirror every mirrored pair (.forSession), save pairs JSON
//   spike-mirror-config restore         re-mirror pairs from the saved JSON
//
// Needs a real external display attached and mirroring enabled to be meaningful.
// No TCC permission required for display configuration.

import CoreGraphics
import Foundation

let pairsFile: URL = {
    let src = URL(fileURLWithPath: #filePath)
    return src.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("out/mirror-pairs.json")
}()

struct Pair: Codable { let secondary: UInt32; let master: UInt32 }

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func describe(_ id: CGDirectDisplayID) -> String {
    let b = CGDisplayBounds(id)
    var s = "display \(id): \(Int(b.width))x\(Int(b.height)) @(\(Int(b.origin.x)),\(Int(b.origin.y)))"
    if CGDisplayIsBuiltin(id) != 0 { s += " [builtin]" }
    if CGDisplayIsMain(id) != 0 { s += " [main]" }
    if CGDisplayIsActive(id) == 0 { s += " [inactive]" }
    let master = CGDisplayMirrorsDisplay(id)
    if master != 0 { s += " [mirrors \(master)]" }
    if CGDisplayIsInMirrorSet(id) != 0 { s += " [in-mirror-set]" }
    if CGDisplayIsAlwaysInMirrorSet(id) != 0 { s += " [ALWAYS-mirrored]" }
    return s
}

func currentPairs() -> [Pair] {
    onlineDisplays().compactMap { id in
        let master = CGDisplayMirrorsDisplay(id)
        return master != 0 ? Pair(secondary: id, master: master) : nil
    }
}

func configure(_ label: String, _ body: (CGDisplayConfigRef) -> CGError) -> Bool {
    var cfg: CGDisplayConfigRef?
    var err = CGBeginDisplayConfiguration(&cfg)
    guard err == .success, let cfg else {
        print("\(label): CGBeginDisplayConfiguration failed: \(err.rawValue)"); return false
    }
    err = body(cfg)
    guard err == .success else {
        print("\(label): configure call failed: \(err.rawValue) — cancelling")
        CGCancelDisplayConfiguration(cfg)
        return false
    }
    err = CGCompleteDisplayConfiguration(cfg, .forSession)
    guard err == .success else {
        // Token is consumed by Complete even on failure — do NOT cancel here.
        print("\(label): CGCompleteDisplayConfiguration failed: \(err.rawValue)")
        return false
    }
    print("\(label): OK")
    return true
}

let mode = CommandLine.arguments.dropFirst().first ?? "status"
switch mode {
case "status":
    for id in onlineDisplays() { print(describe(id)) }

case "break":
    let pairs = currentPairs()
    guard !pairs.isEmpty else { print("nothing is mirrored — attach a display and enable mirroring first"); exit(3) }
    for p in pairs where CGDisplayIsAlwaysInMirrorSet(p.secondary) != 0 {
        print("refusing: display \(p.secondary) is always-in-mirror-set"); exit(4)
    }
    try? FileManager.default.createDirectory(at: pairsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! JSONEncoder().encode(pairs).write(to: pairsFile)
    print("saved pairs: \(pairs.map { "\($0.secondary)→\($0.master)" }.joined(separator: ", "))")
    let ok = configure("break") { cfg in
        for p in pairs {
            let e = CGConfigureDisplayMirrorOfDisplay(cfg, p.secondary, kCGNullDirectDisplay)
            if e != .success { return e }
        }
        return .success
    }
    sleep(2)
    print("--- after break ---")
    for id in onlineDisplays() { print(describe(id)) }
    exit(ok ? 0 : 1)

case "restore":
    guard let data = try? Data(contentsOf: pairsFile),
          let pairs = try? JSONDecoder().decode([Pair].self, from: data) else {
        print("no saved pairs at \(pairsFile.path)"); exit(3)
    }
    let online = Set(onlineDisplays())
    let present = pairs.filter { online.contains($0.secondary) && online.contains($0.master) }
    if present.count < pairs.count { print("warning: some saved displays are no longer online; restoring \(present.count)/\(pairs.count)") }
    let ok = configure("restore") { cfg in
        for p in present {
            let e = CGConfigureDisplayMirrorOfDisplay(cfg, p.secondary, p.master)
            if e != .success { return e }
        }
        return .success
    }
    sleep(2)
    print("--- after restore ---")
    for id in onlineDisplays() { print(describe(id)) }
    exit(ok ? 0 : 1)

default:
    print("usage: spike-mirror-config [status|break|restore]"); exit(64)
}
