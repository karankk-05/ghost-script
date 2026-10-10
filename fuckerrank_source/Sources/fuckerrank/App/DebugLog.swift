import Foundation

func appendLog(_ text: String) {
    let url = URL(fileURLWithPath: "/tmp/fuckerrank.log")
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
    }
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        if let data = (text + "\n").data(using: .utf8) {
            handle.write(data)
        }
        handle.closeFile()
    }
}
