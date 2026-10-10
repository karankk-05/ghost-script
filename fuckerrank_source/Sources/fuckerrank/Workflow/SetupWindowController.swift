import AppKit
import ServiceManagement

@MainActor
final class SetupWindowController: NSObject {
    private unowned let app: AppDelegate
    private var window: NSWindow?
    private let status = NSTextField(wrappingLabelWithString: "")
    private let solveModel = NSTextField(string: UserDefaults.standard.string(forKey: "solveModel") ?? "gemini-3.1-pro")
    private let flashModel = NSTextField(string: UserDefaults.standard.string(forKey: "flashModel") ?? "gemini-3.8-flash")
    private var installing = false

    init(app: AppDelegate) { self.app = app }
    func hide() { window?.orderOut(nil) }
    func show() {
        guard app.requireLicense() else { return }
        if window == nil { buildWindow() }
        if !installing { status.stringValue = DependencyInstaller.existingCLI == nil ? "Antigravity needs to be installed." : "Antigravity is available. Use your own Google account to sign in." }
        if let error = app.state.hotKeyError { status.stringValue += "\n\n" + error }
        window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 640),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "fuckerrank — Setup"
        window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let title = NSTextField(labelWithString: "You're activated. Finish setup once.")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(status)
        stack.addArrangedSubview(NSButton(title: "Install Antigravity", target: self, action: #selector(installCLI)))
        stack.addArrangedSubview(NSButton(title: "Sign In to Antigravity…", target: self, action: #selector(signIn)))
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "Sign-in opens Google's CLI in Terminal. Follow its prompts using your own account; no command typing is needed."))
        stack.addArrangedSubview(NSButton(title: "Allow Screen Recording…", target: self, action: #selector(screenPermission)))
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "macOS requires your approval for screenshots. After granting permission, quit and reopen fuckerrank."))
        stack.addArrangedSubview(NSTextField(labelWithString: "Keyboard shortcuts work while the app is running:"))
        let shortcuts = NSTextField(wrappingLabelWithString: "⌃⇧S  Take screenshot\n⌃⇧M  Margherita Pizza\n⌃⇧R  Flash Pizza\n⌃⇧E  Show / hide answer\n⌃⇧Q  Change color\n⌃⇧D  Show / hide prompt")
        shortcuts.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        stack.addArrangedSubview(shortcuts)
        stack.addArrangedSubview(NSButton(title: "Enable Open at Login", target: self, action: #selector(enableLogin)))
        stack.addArrangedSubview(NSTextField(labelWithString: "Models (use IDs available in your Antigravity account)"))
        stack.addArrangedSubview(solveModel); stack.addArrangedSubview(flashModel)
        stack.addArrangedSubview(NSButton(title: "Save Models", target: self, action: #selector(saveModels)))
        for case let field as NSTextField in stack.arrangedSubviews {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 502).isActive = true
        }
        window.contentView = stack; self.window = window
    }
    @objc private func installCLI() {
        guard app.requireLicense(), !installing else { return }
        installing = true
        Task {
            defer { installing = false }
            do { try await DependencyInstaller.install { [self] in status.stringValue = $0 } }
            catch { status.stringValue = error.localizedDescription }
        }
    }
    @objc private func signIn() {
        guard app.requireLicense(), let cli = DependencyInstaller.existingCLI else {
            status.stringValue = "Install Antigravity first."; return
        }
        // Only the public CLI executable is passed to Terminal; credentials stay with Google.
        let command = "exec " + "'" + cli.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { status.stringValue = "Could not open sign-in. Allow Terminal automation in Privacy & Security. \(error)" }
    }
    @objc private func screenPermission() {
        guard app.requireLicense() else { return }
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
    @objc private func enableLogin() {
        guard app.requireLicense() else { return }
        do { try SMAppService.mainApp.register(); status.stringValue = "Open at Login is enabled. Approve it in System Settings if macOS asks." }
        catch { status.stringValue = error.localizedDescription }
    }
    @objc private func saveModels() {
        guard app.requireLicense() else { return }
        let main = solveModel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let flash = flashModel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !main.isEmpty, !flash.isEmpty else { status.stringValue = "Both model names are required."; return }
        UserDefaults.standard.set(main, forKey: "solveModel"); UserDefaults.standard.set(flash, forKey: "flashModel")
        status.stringValue = "Model preferences saved."
    }
}
