import AppKit

/// Slim strip across the top of the overlay that acts as the window-drag
/// handle (the web content below is drag-to-select instead). Uses an explicit
/// performDrag — the implicit mouseDownCanMoveWindow path is unreliable when
/// layered over a WKWebView.
final class DragStripView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSRect(x: bounds.midX - 22, y: bounds.midY - 2.5, width: 44, height: 5)
        NSColor.black.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 2.5, yRadius: 2.5).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
