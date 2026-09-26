import Foundation

/// Watches a single file with a kqueue DispatchSource. Handles editors that
/// atomically replace files (vim/VS Code rename-over, TextEdit atomic save)
/// by re-opening the path on .rename/.delete with bounded retries. Events are
/// debounced 100 ms; callbacks arrive on an internal queue — callers hop to
/// the MainActor themselves.
final class FileWatcher: @unchecked Sendable {
    enum Event {
        case changed(String)
        case failure(String)
    }

    private let path: String
    private let queue = DispatchQueue(label: "io.koerbaecher.ghostscreen.filewatch")
    private let handler: (Event) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var debounceWork: DispatchWorkItem?
    private var isCancelled = false

    init(url: URL, handler: @escaping (Event) -> Void) {
        self.path = url.path
        self.handler = handler
        queue.async { [weak self] in
            self?.arm()
            self?.readNow() // initial content delivery
        }
    }

    func cancel() {
        queue.async { [self] in
            isCancelled = true
            debounceWork?.cancel()
            source?.cancel() // cancel handler closes the fd
            source = nil
        }
    }

    // MARK: - queue-confined

    private func arm() {
        guard !isCancelled else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            handler(.failure("Cannot watch \(path): \(String(cString: strerror(errno)))"))
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .link],
            queue: queue)
        src.setCancelHandler { close(fd) }
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            if src.data.contains(.delete) || src.data.contains(.rename) {
                self.rearm()
            } else {
                self.scheduleRead()
            }
        }
        source = src
        src.resume()
    }

    /// Atomic saves briefly remove the path — retry the reopen up to 20 × 50 ms.
    private func rearm() {
        source?.cancel()
        source = nil
        var attempts = 0
        func tryReopen() {
            guard !isCancelled else { return }
            if FileManager.default.fileExists(atPath: path) {
                arm()
                scheduleRead()
            } else if attempts < 20 {
                attempts += 1
                queue.asyncAfter(deadline: .now() + .milliseconds(50)) { tryReopen() }
            } else {
                handler(.failure("File disappeared: \(path)"))
            }
        }
        tryReopen()
    }

    private func scheduleRead() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.readNow() }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }

    private func readNow() {
        guard !isCancelled else { return }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            handler(.changed(text))
        } catch {
            handler(.failure("Read failed: \(error.localizedDescription)"))
        }
    }
}
