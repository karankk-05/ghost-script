import AppKit
import QuartzCore

/// BeamerRenderer facade: composes CaptureEngine + MirrorRenderView. The only
/// type the display subsystem ever touches from Capture/.
@MainActor
final class CapturePipeline: BeamerRenderer {
    private let engine = CaptureEngine()
    private let view = MirrorRenderView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))

    var onStats: ((CaptureStats) -> Void)?
    var onFailure: ((CaptureFailure) -> Void)?

    init() {
        engine.onFailure = { [weak self] failure in
            self?.onFailure?(failure)
        }
        engine.meter.onStats = { [weak self] stats in
            Task { @MainActor in
                self?.onStats?(stats)
            }
        }
    }

    func makeOutputView() -> NSView {
        view
    }

    func start(capturingDisplay displayID: CGDirectDisplayID,
               excludingWindowNumbers: [Int],
               outputPixelSize: CGSize,
               outputMaxHz: Int) async throws {
        view.flush()
        try await engine.start(displayID: displayID,
                               excludingWindowNumbers: excludingWindowNumbers,
                               renderer: view.videoRenderer,
                               outputPixelSize: outputPixelSize,
                               maxHz: outputMaxHz)
    }

    func updateOutput(pixelSize: CGSize, maxHz: Int) async {
        await engine.updateOutput(pixelSize: pixelSize, maxHz: maxHz)
    }

    func rebuildFilter(excludingWindowNumbers: [Int]) async {
        await engine.rebuildFilter(excludingWindowNumbers: excludingWindowNumbers)
    }

    func stop() async {
        await engine.stop()
        view.flush()
    }
}
