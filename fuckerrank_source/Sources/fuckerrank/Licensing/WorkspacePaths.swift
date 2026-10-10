import Foundation

enum WorkspacePaths {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/fuckerrank", isDirectory: true)
    static let screenshots = root.appendingPathComponent("ss", isDirectory: true)
    static let archive = screenshots.appendingPathComponent("archive", isDirectory: true)
    static let delivery = root.appendingPathComponent("delivery", isDirectory: true)
    static let prompt = delivery.appendingPathComponent("custom_prompt.txt")
    static let notes = delivery.appendingPathComponent("margherita_pizza.md")
    static let license = root.appendingPathComponent("license.txt")
    static let deviceKey = root.appendingPathComponent("device-key.bin")
    static let tools = root.appendingPathComponent("bin", isDirectory: true)
    static let agy = tools.appendingPathComponent("agy")

    static func prepare() throws {
        for url in [root, screenshots, archive, delivery, tools] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        if !FileManager.default.fileExists(atPath: notes.path) {
            try "Your answers will appear here.\n".write(to: notes, atomically: true, encoding: .utf8)
        }
    }
    static func savePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
