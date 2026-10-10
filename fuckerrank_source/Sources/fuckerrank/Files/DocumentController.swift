import AppKit
import UniformTypeIdentifiers

/// Opens markdown files (open panel, drops, Dock, relaunch restore) and owns
/// the live-reload watcher. Read failures never clear the last rendered
/// content — they surface in AppState.fileError only.
@MainActor
final class DocumentController {
    private let state: AppState
    private var watcher: FileWatcher?
    /// Guards against in-flight events from a superseded watcher landing
    /// after a newer file's content (cancel() is async on the old queue).
    private var openEpoch = 0
    private static let lastPathKey = "lastNotesPath"

    init(state: AppState) {
        self.state = state
    }

    func openPanel() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.plainText]
        if let md = UTType(filenameExtension: "md") { types.insert(md, at: 0) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    func restoreLastFile() {
        guard let path = UserDefaults.standard.string(forKey: Self.lastPathKey),
              FileManager.default.fileExists(atPath: path) else { return }
        open(url: URL(fileURLWithPath: path),
             revealOverlay: UserDefaults.standard.bool(forKey: "overlayVisible"))
    }

    func open(url: URL, revealOverlay: Bool = true) {
        watcher?.cancel()
        state.notesURL = url
        state.fileError = nil
        UserDefaults.standard.set(url.path, forKey: Self.lastPathKey)
        state.recentNotesPaths = ([url.path] + state.recentNotesPaths.filter { $0 != url.path })
            .prefix(5).map { $0 }
        openEpoch += 1
        let epoch = openEpoch
        watcher = FileWatcher(url: url) { [weak self] event in
            Task { @MainActor in
                guard let self, self.openEpoch == epoch else { return }
                switch event {
                case .changed(let content):
                    self.state.markdown = content
                    self.state.fileError = nil
                case .failure(let message):
                    self.state.fileError = message // keep last rendered content
                }
            }
        }
        if revealOverlay {
            state.overlayVisible = true
        }
    }
}
