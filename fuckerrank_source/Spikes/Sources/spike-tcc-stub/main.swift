// Spike C stub — assembled into a .app by assemble-stub.sh and launched via
// `open`, so TCC attributes Screen Recording to the stub bundle, not the shell.
// Writes its permission status to Spikes/out/tcc-result.txt and exits.
// Pass --request to trigger the system permission prompt.

import AppKit
import ScreenCaptureKit

let resultFile = URL(fileURLWithPath: "/Users/m.koerbaecher/Codespace/fuckerrank/Spikes/out/tcc-result.txt")

@MainActor
func run() async {
    var lines: [String] = []
    let stamp = ISO8601DateFormatter().string(from: Date())
    let build = ProcessInfo.processInfo.environment["SPIKE_BUILD_TAG"]
        ?? (Bundle.main.infoDictionary?["SpikeBuildTag"] as? String ?? "unknown")
    lines.append("time=\(stamp) buildTag=\(build) bundle=\(Bundle.main.bundleIdentifier ?? "nil")")
    let preflight = CGPreflightScreenCaptureAccess()
    lines.append("CGPreflightScreenCaptureAccess=\(preflight)")
    if !preflight && CommandLine.arguments.contains("--request") {
        lines.append("requesting…")
        CGRequestScreenCaptureAccess()
    }
    do {
        let content = try await SCShareableContent.current
        lines.append("SCShareableContent: OK (\(content.displays.count) displays, \(content.windows.count) windows)")
    } catch {
        lines.append("SCShareableContent: ERROR \(error)")
    }
    try? FileManager.default.createDirectory(at: resultFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? lines.joined(separator: "\n").appending("\n---\n")
        .appendingToFile(resultFile)
    exit(0)
}

extension String {
    func appendingToFile(_ url: URL) throws {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data(using: .utf8)!)
        } else {
            try write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in await run() }
app.run()
