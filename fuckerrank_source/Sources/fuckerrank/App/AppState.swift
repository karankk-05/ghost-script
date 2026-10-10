import Foundation
import Observation

/// Shared UI state. Owned by AppDelegate; SwiftUI reads it via .environment,
/// AppKit controllers react to it via observeOnMain.
@MainActor
@Observable
final class AppState {
    var isActivated = false
    var licenseOwner = ""
    var workflowError: String?
    var hotKeyError: String?
    var notesURL: URL?
    var markdown: String = ""
    var fileError: String?

    var overlayVisible = false {
        didSet { UserDefaults.standard.set(overlayVisible, forKey: "overlayVisible") }
    }

    /// Whole-panel alpha; UI clamps to ≥ 0.25 so notes never become invisible.
    var overlayOpacity: Double = UserDefaults.standard.object(forKey: "overlayOpacity") as? Double ?? 0.92 {
        didSet { UserDefaults.standard.set(overlayOpacity, forKey: "overlayOpacity") }
    }

    var theme: String = UserDefaults.standard.string(forKey: "Theme") ?? "white" {
        didSet { UserDefaults.standard.set(theme, forKey: "Theme") }
    }
    
    init() {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let newTheme = UserDefaults.standard.string(forKey: "Theme"), newTheme != self?.theme {
                    self?.theme = newTheme
                }
            }
        }
    }

    /// False when launched as a bare executable (`swift run`) — no bundle
    /// identity means no stable TCC grant and no Dock drops. `make run` is
    /// the supported dev loop.
    let isBundled = Bundle.main.bundleIdentifier != nil

    // MARK: - Displays / mirror mode

    var topology = DisplayTopology(displays: [])
    var mirrorError: String?
    var mirrorStatus: MirrorStatus = .off
    var mirrorDegraded = false
    var permissionState: PermissionState = .unknown

    /// Pair count of a crash marker found at launch; > 0 shows the restore banner.
    var restoreOfferPairCount = 0

    /// User's beamer target when several externals are attached.
    var selectedExternalUUID: UUID? = UserDefaults.standard.string(forKey: "selectedExternalUUID")
        .flatMap(UUID.init(uuidString:)) {
        didSet {
            UserDefaults.standard.set(selectedExternalUUID?.uuidString, forKey: "selectedExternalUUID")
        }
    }

    /// Capture at the built-in display's native pixel size instead of
    /// output-fitted (sharper on very high-res beamers, more bandwidth).
    var nativeSourceCapture = UserDefaults.standard.bool(forKey: "nativeSourceCapture") {
        didSet { UserDefaults.standard.set(nativeSourceCapture, forKey: "nativeSourceCapture") }
    }

    var recentNotesPaths: [String] = UserDefaults.standard.stringArray(forKey: "recentNotesPaths") ?? [] {
        didSet { UserDefaults.standard.set(recentNotesPaths, forKey: "recentNotesPaths") }
    }
}
