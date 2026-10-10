import AppKit

/// Builds the notes panel + web view + renderer and keeps them in sync with
/// AppState (visibility, opacity, markdown content).
@MainActor
final class OverlayWindowController {
    private let state: AppState
    let panel = NotesPanel()
    private let renderer = MarkdownRenderer()

    init(state: AppState, documents: DocumentController) {
        self.state = state
        renderer.webView.onFileDropped = { [weak documents] url in
            Task { @MainActor in documents?.open(url: url) }
        }

        // Web view fills the panel; a slim native strip floats over its top
        // edge as the window-drag handle (the web content itself is
        // drag-to-select so notes can be copied).
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let desiredWidth = screen.width * 0.5
        let desiredHeight: CGFloat = 80 // 3 lines of text
        
        let container = NSView(frame: NSRect(x: 0, y: 0, width: desiredWidth, height: desiredHeight))
        container.autoresizesSubviews = true
        renderer.webView.frame = container.bounds
        renderer.webView.autoresizingMask = [.width, .height]
        let strip = DragStripView(frame: NSRect(x: 0, y: container.bounds.height - 20,
                                                width: container.bounds.width, height: 20))
        strip.autoresizingMask = [.width, .minYMargin]
        container.addSubview(renderer.webView)
        container.addSubview(strip)

        panel.contentView = container
        
        // Position it nicely in the top-center of the screen
        let xPos = screen.minX + (screen.width - desiredWidth) / 2
        let yPos = screen.maxY - desiredHeight - 40 // a bit below the menu bar
        panel.setFrame(NSRect(x: xPos, y: yPos, width: desiredWidth, height: desiredHeight), display: true)

        // Display changes can strand a borderless window off-screen — AppKit
        // only rescues titled windows.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.ensureOnScreen() }
        }
    }

    /// The drag strip must be reachable on SOME screen, else reset to a
    /// sane frame on the main screen.
    private func ensureOnScreen() {
        let frame = panel.frame
        let strip = NSRect(x: frame.minX, y: frame.maxY - 20, width: frame.width, height: 20)
        let reachable = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(strip)
            return overlap.width >= 40 && overlap.height >= 10
        }
        guard !reachable, let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let desiredWidth = screen.width * 0.5
        let desiredHeight: CGFloat = 80
        panel.setFrame(NSRect(x: screen.minX + (screen.width - desiredWidth) / 2, y: screen.maxY - desiredHeight - 40, width: desiredWidth, height: desiredHeight),
                       display: true)
    }

    /// Start reacting to AppState. Called once from applicationDidFinishLaunching.
    func bind() {
        observeOnMain { [weak self] in
            guard let self else { return }
            panel.alphaValue = max(0.25, state.overlayOpacity)
            if state.notesURL != nil {
                renderer.render(markdown: state.markdown)
            }
            renderer.setTheme(state.theme)
            // OS mirroring clones the framebuffer — capture protection does
            // not apply there, so the notes ARE on the external display.
            renderer.setMirrorWarning(state.topology.isMirroring)
            if state.overlayVisible {
                if !panel.isVisible { panel.orderFrontRegardless() }
            } else if panel.isVisible {
                panel.orderOut(nil)
            }
        }
    }
}
