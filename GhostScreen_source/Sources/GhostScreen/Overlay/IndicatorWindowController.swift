import AppKit

final class IndicatorPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 10, y: 10, width: 5, height: 5),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        isRestorable = false
        level = .screenSaver
        if !NotesPanel.captureProtectionDisabled {
            sharingType = .none
        }
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
    }
    
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class IndicatorWindowController {
    let panel = IndicatorPanel()
    let dotView = NSView(frame: NSRect(x: 0, y: 0, width: 5, height: 5))

    init() {
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 2.5
        dotView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = dotView
    }

    func setIndicator(color: String) {
        if color == "off" {
            panel.orderOut(nil)
            return
        }
        
        let nsColor: NSColor
        switch color {
        case "green": nsColor = .systemGreen
        case "yellow": nsColor = .systemYellow
        case "red": nsColor = .systemRed
        default: nsColor = .systemBlue
        }
        
        dotView.layer?.backgroundColor = nsColor.cgColor
        panel.orderFront(nil)
    }
}
