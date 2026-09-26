import AppKit

final class StealthTextView: NSTextView {
    override func resetCursorRects() {
        self.addCursorRect(self.bounds, cursor: .arrow)
    }
}

final class PromptPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 100, y: 100, width: 500, height: 80),
                   styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        isRestorable = false
        level = .floating
        if !NotesPanel.captureProtectionDisabled {
            sharingType = .none
        }
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }
    
    override var canBecomeKey: Bool {
        return true
    }
}

@MainActor
final class PromptWindowController: NSObject, NSTextViewDelegate {
    let panel = PromptPanel()
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 80))
    let textView: StealthTextView

    private var debounceTimer: Timer?

    override init() {
        let contentSize = scrollView.contentSize
        textView = StealthTextView(frame: NSRect(origin: .zero, size: contentSize))
        
        super.init()
        
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        
        textView.minSize = NSSize(width: 0.0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        
        textView.delegate = self
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textColor = .white
        textView.font = .systemFont(ofSize: 20)
        textView.insertionPointColor = .clear
        
        // Disable all popups and corrections
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        
        scrollView.documentView = textView
        panel.contentView = scrollView
        
        // Load existing prompt if any
        let path = "/Users/karan/Documents/lesss_gooo/delivery/custom_prompt.txt"
        if let text = try? String(contentsOfFile: path, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textView.string = text
        } else {
            textView.string = "cpp"
        }
        
        if let savedTheme = UserDefaults.standard.string(forKey: "Theme") {
            setTheme(savedTheme)
        }
    }
    
    func textDidChange(_ notification: Notification) {
        debounceTimer?.invalidate()
        let text = textView.string
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
            let path = "/Users/karan/Documents/lesss_gooo/delivery/custom_prompt.txt"
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func toggle() {
        if panel.isVisible {
            // Force save
            let path = "/Users/karan/Documents/lesss_gooo/delivery/custom_prompt.txt"
            try? textView.string.write(toFile: path, atomically: true, encoding: .utf8)
            panel.orderOut(nil)
        } else {
            if let screen = NSScreen.main {
                let width = screen.frame.width * 0.5
                let height: CGFloat = 80
                let x = (screen.frame.width - width) / 2
                let y = screen.frame.height - height - 100
                panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
            }
            panel.makeKeyAndOrderFront(nil)
        }
    }
    
    func setTheme(_ theme: String) {
        panel.backgroundColor = .clear
        
        let color: NSColor
        if theme == "black" {
            color = .black
        } else if theme == "green" {
            color = NSColor(red: 106/255.0, green: 153/255.0, blue: 85/255.0, alpha: 1.0)
        } else {
            color = NSColor(white: 1.0, alpha: 0.96)
        }
        
        textView.textColor = color
        
        // Instantly update any existing text
        if let textStorage = textView.textStorage {
            let range = NSRange(location: 0, length: textStorage.length)
            textStorage.addAttribute(.foregroundColor, value: color, range: range)
        }
    }
}
