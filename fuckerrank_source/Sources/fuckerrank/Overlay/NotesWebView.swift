import AppKit
import WebKit

/// WKWebView tuned for the overlay: background-drag moves the window,
/// context menu is disabled, and markdown files can be dropped directly
/// onto the notes.
final class NotesWebView: WKWebView {
    var onFileDropped: ((URL) -> Void)?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // False so drags SELECT text (copy & paste support); the window is moved
    // via the DragStripView handle or ⌘-drag anywhere.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            window?.performDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
    }

    // MARK: - Drag & drop of markdown files

    private static let extensions = ["md", "markdown", "mdown", "txt"]

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURL(sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedFileURL(sender) else { return false }
        onFileDropped?(url)
        return true
    }

    private func droppedFileURL(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.first { Self.extensions.contains($0.pathExtension.lowercased()) }
    }
}
