import AppKit
import SwiftUI

/// Menu bar presence: a 👻 status item with the overlay/mirror controls, so
/// the app is reachable without the Dock or the control window.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let state: AppState
    private unowned let appDelegate: AppDelegate
    private var statusItem: NSStatusItem?

    init(state: AppState, appDelegate: AppDelegate) {
        self.state = state
        self.appDelegate = appDelegate
        super.init()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "👻"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        observeOnMain { [weak self] in
            guard let self else { return }
            let exposed = state.topology.isMirroring && state.mirrorStatus == .off
            statusItem?.button?.title = exposed ? "👻⚠️" : "👻"
            statusItem?.button?.toolTip = exposed
                ? "fuckerrank — notes are VISIBLE on the external display (macOS mirroring is on)"
                : "fuckerrank"
        }
    }

    // Rebuilt every time the menu opens, so it always reflects current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard state.isActivated else {
            let status = NSMenuItem(title: "Activation required", action: nil, keyEquivalent: "")
            status.isEnabled = false; menu.addItem(status)
            addItem(menu, "Activate This Mac…", #selector(activate))
            menu.addItem(.separator())
            addItem(menu, "Quit fuckerrank", #selector(quit))
            return
        }
        let owner = NSMenuItem(title: "Licensed to \(state.licenseOwner)", action: nil, keyEquivalent: "")
        owner.isEnabled = false; menu.addItem(owner)
        addItem(menu, "Take Screenshot  ⌃⇧S", #selector(screenshot))
        addItem(menu, "Margherita Pizza  ⌃⇧M", #selector(solve))
        addItem(menu, "Flash Pizza  ⌃⇧R", #selector(flash))
        addItem(menu, "Show / Hide Answer  ⌃⇧E", #selector(answer))
        addItem(menu, "Change Color  ⌃⇧Q", #selector(theme))
        addItem(menu, "Show / Hide Prompt  ⌃⇧D", #selector(prompt))
        if appDelegate.workflow.isBusy { addItem(menu, "Cancel Current Request", #selector(cancelRequest)) }
        addItem(menu, "Setup…", #selector(setup))
        if state.hotKeyError != nil {
            let warning = NSMenuItem(title: "Keyboard shortcut conflict — open Setup", action: nil, keyEquivalent: "")
            warning.isEnabled = false; menu.addItem(warning)
        }
        menu.addItem(.separator())

        let status = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if state.topology.isMirroring, state.mirrorStatus == .off {
            let warn = NSMenuItem(title: "⚠️ Notes visible on external display!",
                                  action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }
        menu.addItem(.separator())

        addItem(menu, state.overlayVisible ? "Hide Notes Overlay" : "Show Notes Overlay",
                #selector(toggleOverlay))
        addItem(menu, "Open Notes…", #selector(openNotes))
        menu.addItem(.separator())

        switch state.mirrorStatus {
        case .off, .failed:
            let item = addItem(menu, "Start Mirror", #selector(startMirror))
            item.isEnabled = !state.topology.externals.isEmpty
        case .starting:
            let item = addItem(menu, "Starting…", nil)
            item.isEnabled = false
        case .active, .suspended:
            addItem(menu, "Stop Mirror", #selector(stopMirror))
        case .stoppedBySystem:
            addItem(menu, "Resume Mirror", #selector(resumeMirror))
            addItem(menu, "Stop Mirror", #selector(stopMirror))
        }
        menu.addItem(.separator())

        addItem(menu, "Open fuckerrank Window", #selector(openMainWindow))
        addItem(menu, "Quit fuckerrank", #selector(quit))
    }

    private func statusText() -> String {
        switch state.mirrorStatus {
        case .off: return "Mirror: off"
        case .starting(let phase): return "Mirror: \(phase)"
        case .active(let fps): return String(format: "Mirror: active — %.0f fps", fps)
        case .suspended: return "Mirror: waiting for display"
        case .stoppedBySystem: return "Mirror: stopped by system"
        case .failed: return "Mirror: failed (see window)"
        }
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func toggleOverlay() { appDelegate.toggleOverlay() }
    @objc private func activate() { appDelegate.showActivation() }
    @objc private func setup() { appDelegate.showSetup() }
    @objc private func screenshot() { appDelegate.workflow.perform(.screenshot) }
    @objc private func solve() { appDelegate.workflow.perform(.solve) }
    @objc private func flash() { appDelegate.workflow.perform(.flash) }
    @objc private func answer() { appDelegate.workflow.perform(.notes) }
    @objc private func theme() { appDelegate.workflow.perform(.theme) }
    @objc private func prompt() { appDelegate.workflow.perform(.prompt) }
    @objc private func cancelRequest() { appDelegate.workflow.cancel() }
    @objc private func openNotes() {
        guard appDelegate.requireLicense() else { return }
        NSApp.activate(ignoringOtherApps: true)
        appDelegate.documents.openPanel()
    }
    @objc private func startMirror() { guard appDelegate.requireLicense() else { return }; Task { await appDelegate.mirrorController.start() } }
    @objc private func stopMirror() { Task { await appDelegate.mirrorController.stop() } }
    @objc private func resumeMirror() { guard appDelegate.requireLicense() else { return }; Task { await appDelegate.mirrorController.resumeCapture() } }
    @objc private func openMainWindow() {
        guard appDelegate.requireLicense() else { return }
        NSApp.activate(ignoringOtherApps: true)
        if appDelegate.settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "fuckerrank Settings"
            // Use SwiftUI to host the ContentView
            let hosting = NSHostingView(rootView: ContentView(appDelegate: appDelegate).environment(appDelegate.state))
            window.contentView = hosting
            window.center()
            appDelegate.settingsWindow = window
        }
        appDelegate.settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
