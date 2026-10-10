import AppKit

/// Lifecycle of the fullscreen output window on the beamer display.
@MainActor
final class BeamerOutputWindowController {
    private(set) var window: BeamerOutputWindow?

    var windowNumber: Int? {
        window.map(\.windowNumber)
    }

    func show(on screen: NSScreen, hosting view: NSView) {
        close()
        let w = BeamerOutputWindow(screen: screen)
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        w.contentView = view
        w.orderFrontRegardless()
        w.setFrame(screen.frame, display: true) // after ordering — some screens report late
        window = w
    }

    func refit(to screen: NSScreen) {
        window?.setFrame(screen.frame, display: true)
    }

    func close() {
        guard let w = window else { return }
        w.orderOut(nil)
        w.contentView = NSView() // detach the render view so it can be re-hosted
        window = nil
    }
}
