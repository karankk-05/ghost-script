import CoreMedia
import ScreenCaptureKit

/// Pure SCStreamConfiguration factory. Output-fitted sizing: SCK performs the
/// single high-quality scale into the output's pixel budget, and the display
/// layer then composites ~1:1 (plus letterboxing via videoGravity).
enum CaptureConfigBuilder {
    static func makeConfig(filter: SCContentFilter,
                           outputPixelSize: CGSize,
                           maxHz: Int) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()

        let srcW = Double(filter.contentRect.width) * Double(filter.pointPixelScale)
        let srcH = Double(filter.contentRect.height) * Double(filter.pointPixelScale)
        var w = srcW, h = srcH
        if outputPixelSize.width > 1, outputPixelSize.height > 1, srcW > 1, srcH > 1 {
            // Never upscale at capture time — the layer can do that for free.
            let scale = min(Double(outputPixelSize.width) / srcW,
                            Double(outputPixelSize.height) / srcH,
                            1.0)
            w = srcW * scale
            h = srcH * scale
        }
        cfg.width = max(2, Int(w) & ~1)
        cfg.height = max(2, Int(h) & ~1)

        cfg.pixelFormat = kCVPixelFormatType_32BGRA // no chroma subsampling on text
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.minimumFrameInterval = CMTime(value: 1,
                                          timescale: CMTimeScale(min(60, max(24, maxHz))))
        cfg.queueDepth = 5
        cfg.showsCursor = true
        cfg.capturesAudio = false
        cfg.preservesAspectRatio = true
        cfg.backgroundColor = CGColor.black
        cfg.streamName = "fuckerrank Mirror"
        cfg.presenterOverlayPrivacyAlertSetting = .never
        if #available(macOS 15.0, *) {
            cfg.showMouseClicks = false
        }
        return cfg
    }
}
