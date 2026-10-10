import Foundation
import CryptoKit

@MainActor
enum DependencyInstaller {
    static var existingCLI: URL? {
        let candidates = [WorkspacePaths.agy, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"), URL(fileURLWithPath: "/usr/local/bin/agy")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    private struct Manifest: Decodable { let url: String; let sha512: String; let version: String }
    static func install(progress: @escaping (String) -> Void) async throws {
        // This endpoint is published in Google's official CLI installer.
        let manifestURL = URL(string: "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/darwin_arm64.json")!
        progress("Checking Google's current Antigravity release…")
        let (data, response) = try await URLSession.shared.data(from: manifestURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw failure("Google's release manifest could not be downloaded.") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard let url = URL(string: manifest.url), url.scheme == "https", manifest.sha512.count == 128 else {
            throw failure("Google's release manifest is invalid.")
        }
        progress("Downloading Antigravity \(manifest.version)…")
        let (download, downloadResponse) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: download) }
        guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else { throw failure("Antigravity could not be downloaded.") }
        progress("Verifying the download…")
        let hash = SHA512.hash(data: try Data(contentsOf: download, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard hash == manifest.sha512.lowercased() else { throw failure("The download checksum does not match Google's manifest. Installation stopped.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("agy-install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let candidate = temporary.appendingPathComponent("agy")
        if url.path.hasSuffix(".tar.gz") {
            let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xzf", download.path, "-C", temporary.path, "antigravity"], directory: temporary)
            guard result.status == 0 else { throw failure("Google's archive could not be extracted.") }
            let extracted = temporary.appendingPathComponent("antigravity")
            let values = try extracted.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw failure("Google's archive contains an invalid executable.") }
            try FileManager.default.moveItem(at: extracted, to: candidate)
        } else { try FileManager.default.copyItem(at: download, to: candidate) }
        // Install in our private data folder; do not change shell profiles or copy credentials.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.path)
        if FileManager.default.fileExists(atPath: WorkspacePaths.agy.path) {
            _ = try FileManager.default.replaceItemAt(WorkspacePaths.agy, withItemAt: candidate)
        } else { try FileManager.default.moveItem(at: candidate, to: WorkspacePaths.agy) }
        progress("Antigravity is installed. Sign in with your own Google account.")
    }
    private static func failure(_ text: String) -> Error {
        NSError(domain: "Antigravity Setup", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
