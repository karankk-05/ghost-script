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
                ? "GhostScreen — notes are VISIBLE on the external display (macOS mirroring is on)"
                : "GhostScreen"
        }
    }

    // Rebuilt every time the menu opens, so it always reflects current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

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

        addItem(menu, "Open GhostScreen Window", #selector(openMainWindow))
        addItem(menu, "Quit GhostScreen", #selector(quit))
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
    @objc private func openNotes() {
        NSApp.activate(ignoringOtherApps: true)
        appDelegate.documents.openPanel()
    }
    @objc private func startMirror() { Task { await appDelegate.mirrorController.start() } }
    @objc private func stopMirror() { Task { await appDelegate.mirrorController.stop() } }
    @objc private func resumeMirror() { Task { await appDelegate.mirrorController.resumeCapture() } }
    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if appDelegate.settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "GhostScreen Settings"
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
