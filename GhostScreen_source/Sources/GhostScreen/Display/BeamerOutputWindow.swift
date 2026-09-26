import AppKit

/// Fullscreen black window covering the ENTIRE external display, menu bar
/// area included — that's why it sits at CGShieldingWindowLevel instead of
/// using NSApplication.presentationOptions (which is app-global and would
/// also hide the menu bar on the captured built-in display).
final class BeamerOutputWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        // .readOnly, NOT .none: sharing the beamer display in Zoom is a real
        // scenario, and our own stream never sees this window anyway because
        // it is always in the filter's excludingWindows.
        sharingType = .readOnly
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true // stray clicks fall through, never swallowed
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
