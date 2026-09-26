import AppKit

/// The floating notes window. Its entire reason to exist is
/// `sharingType = .none`: the compositor excludes it from every capture path
/// (screenshots, ScreenCaptureKit, QuickTime, Zoom/Meet/Teams — and our own
/// beamer mirror stream), recompositing the content behind it. Verified
/// empirically on this machine by Spikes/spike-capture-exclusion.
final class NotesPanel: NSPanel {
    /// Single tunable stacking constant. .screenSaver wins over fullscreen
    /// presentation apps; drop to .statusBar if it ever fights system UI.
    static let overlayLevel: NSWindow.Level = .screenSaver

    /// Dev-only escape hatch so the overlay can be captured for testing and
    /// documentation screenshots. Decided once at init — protection is never
    /// toggled at runtime.
    static let captureProtectionDisabled =
        ProcessInfo.processInfo.environment["GHOSTSCREEN_DISABLE_CAPTURE_PROTECTION"] == "1"

    init() {
        super.init(contentRect: NSRect(x: 200, y: 200, width: 420, height: 560),
                   styleMask: [.titled, .nonactivatingPanel, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        
        isFloatingPanel = true
        isRestorable = false
        level = Self.overlayLevel
        if !Self.captureProtectionDisabled {
            sharingType = .none // set once, before any orderFront; never changed
        }
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        minSize = NSSize(width: 240, height: 40)
        animationBehavior = .none
    }

    // Key so the web view can receive scroll/arrow keys; never main, and
    // .nonactivatingPanel keeps the presenting app (Keynote etc.) active.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    #if DEBUG
    override func orderFront(_ sender: Any?) {
        assert(Self.captureProtectionDisabled || sharingType == .none,
               "notes panel must stay capture-protected")
        super.orderFront(sender)
    }
    #endif
}
