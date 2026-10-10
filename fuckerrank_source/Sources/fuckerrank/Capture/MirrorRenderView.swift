import AppKit
import AVFoundation

/// Layer-hosting view around AVSampleBufferDisplayLayer. `.resizeAspect` on a
/// black layer IS the letterboxing — no manual geometry anywhere.
final class MirrorRenderView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()

    var videoRenderer: AVSampleBufferVideoRenderer {
        displayLayer.sampleBufferRenderer
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor.black
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.backgroundColor = CGColor.black
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func flush() {
        videoRenderer.flush()
    }
}
