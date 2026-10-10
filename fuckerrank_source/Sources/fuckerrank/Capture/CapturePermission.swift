import AppKit
import CoreGraphics
import ScreenCaptureKit

enum PermissionState: Equatable {
    case unknown
    case granted
    case denied
}

/// Single wrapper around the Screen Recording TCC dance. CGPreflight can be
/// stale within a process, so `probe()` (a real SCShareableContent fetch) is
/// the authoritative check. A fresh grant only takes effect after relaunch —
/// UI copy must say so.
@MainActor
final class CapturePermission {
    private(set) var state: PermissionState = .unknown

    func preflight() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func probe() async -> PermissionState {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            state = .granted
        } catch {
            state = .denied
        }
        return state
    }

    /// Triggers the system prompt (first time) or is a no-op; either way the
    /// user finishes in System Settings and relaunches.
    func request() {
        CGRequestScreenCaptureAccess()
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
