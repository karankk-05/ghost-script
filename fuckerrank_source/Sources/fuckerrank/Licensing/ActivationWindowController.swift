import AppKit

@MainActor
final class ActivationWindowController: NSObject {
    private let license: LicenseController
    private let onActivated: () -> Void
    private var window: NSWindow?
    private let requestView = NSTextView()
    private let codeView = NSTextView()
    private let message = NSTextField(wrappingLabelWithString: "")

    init(license: LicenseController, onActivated: @escaping () -> Void) {
        self.license = license; self.onActivated = onActivated
    }
    func show() {
        if window == nil { buildWindow() }
        do { requestView.string = try license.requestCode(); message.stringValue = license.lastError }
        catch { message.stringValue = error.localizedDescription }
        window?.center(); window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Activate fuckerrank"
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let title = NSTextField(labelWithString: "One-time activation for this Mac")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        stack.addArrangedSubview(title)
        let instructions = NSTextField(wrappingLabelWithString:
            "Give this request to the owner. They will provide an activation code. Your license is checked locally; no licensing server is used.")
        instructions.translatesAutoresizingMaskIntoConstraints = false
        instructions.widthAnchor.constraint(equalToConstant: 588).isActive = true
        stack.addArrangedSubview(instructions)
        requestView.isEditable = false
        stack.addArrangedSubview(textArea(requestView, height: 100))
        let buttons = NSStackView(views: [
            NSButton(title: "Copy Request", target: self, action: #selector(copyRequest)),
            NSButton(title: "Save Request…", target: self, action: #selector(saveRequest))])
        stack.addArrangedSubview(buttons)
        stack.addArrangedSubview(NSTextField(labelWithString: "Paste the activation code supplied by the owner"))
        stack.addArrangedSubview(textArea(codeView, height: 100))
        let activate = NSButton(title: "Activate This Mac", target: self, action: #selector(activate))
        stack.addArrangedSubview(activate)
        message.textColor = .secondaryLabelColor
        message.translatesAutoresizingMaskIntoConstraints = false
        message.widthAnchor.constraint(equalToConstant: 588).isActive = true
        stack.addArrangedSubview(message)
        window.contentView = stack
        self.window = window
    }
    private func textArea(_ text: NSTextView, height: CGFloat) -> NSScrollView {
        text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.documentView = text
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 588).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }
    @objc private func copyRequest() {
        guard !requestView.string.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(requestView.string, forType: .string)
    }
    @objc private func saveRequest() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "My-Mac.fuckerrankrequest"
        if panel.runModal() == .OK, let url = panel.url {
            do { try requestView.string.write(to: url, atomically: true, encoding: .utf8) }
            catch { message.stringValue = error.localizedDescription }
        }
    }
    @objc private func activate() {
        do { try license.activate(codeView.string); codeView.string = ""; window?.orderOut(nil); onActivated() }
        catch { message.stringValue = error.localizedDescription }
    }
}
