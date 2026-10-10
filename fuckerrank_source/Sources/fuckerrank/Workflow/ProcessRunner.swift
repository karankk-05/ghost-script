import Foundation

struct CommandResult {
    let output: String
    let error: String
    let status: Int32
}

@MainActor
enum ProcessRunner {
    static func run(_ executable: URL, arguments: [String], directory: URL,
                    onLaunch: ((Process) -> Void)? = nil) async throws -> CommandResult {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("fuckerrank-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stdoutURL = temporary.appendingPathComponent("stdout")
        let stderrURL = temporary.appendingPathComponent("stderr")
        fm.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        fm.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        let process = Process()
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:" + fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        process.environment = environment
        process.standardOutput = stdout; process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                defer { try? FileManager.default.removeItem(at: temporary) }
                do {
                    let output = try String(contentsOf: stdoutURL, encoding: .utf8)
                    let error = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
                    continuation.resume(returning: CommandResult(output: output, error: error, status: process.terminationStatus))
                } catch { continuation.resume(throwing: error) }
            }
            do {
                try process.run()
                try? stdout.close(); try? stderr.close()
                onLaunch?(process)
            } catch {
                process.terminationHandler = nil
                try? stdout.close(); try? stderr.close(); try? fm.removeItem(at: temporary)
                continuation.resume(throwing: error)
            }
        }
    }
}
