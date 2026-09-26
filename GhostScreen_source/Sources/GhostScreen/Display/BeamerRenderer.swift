import AppKit

/// Per-second pipeline health snapshot, produced on the video queue and
/// consumed on the MainActor.
struct CaptureStats: Sendable {
    let fps: Double
    let droppedFrames: Int
    let idleFrames: Int
    /// Seconds since ANY stream callback (complete or idle). A static screen
    /// legitimately goes quiet between idle frames — the stall watchdog keys
    /// off this, not off fps.
    let lastEventAge: TimeInterval

    var looksStalled: Bool { lastEventAge > 3.0 }
}

enum CaptureFailure: Sendable {
    /// User or system hit "Stop sharing" (SCStream -3817 / -3821). Never
    /// silently restarted — surfaced as a one-click "Resume mirror".
    case stopped(reason: String)
    /// Screen Recording TCC missing/revoked (-3801).
    case permissionDenied
    /// Transient error that survived the retry budget.
    case failed(String)
}

/// What the mirror state machine needs from the capture side — implemented
/// by CapturePipeline. This protocol is the only seam between Display/ and
/// Capture/; it deliberately never mentions ScreenCaptureKit types.
@MainActor
protocol BeamerRenderer: AnyObject {
    var onStats: ((CaptureStats) -> Void)? { get set }
    var onFailure: ((CaptureFailure) -> Void)? { get set }

    /// The view to host inside the beamer output window.
    func makeOutputView() -> NSView

    func start(capturingDisplay displayID: CGDirectDisplayID,
               excludingWindowNumbers: [Int],
               outputPixelSize: CGSize,
               outputMaxHz: Int) async throws

    /// Output display reshaped (resolution/refresh change).
    func updateOutput(pixelSize: CGSize, maxHz: Int) async

    /// Window set changed (e.g. output window recreated after hotplug).
    func rebuildFilter(excludingWindowNumbers: [Int]) async

    func stop() async
}
