import AVFoundation
import ScreenCaptureKit

/// SCStreamOutput on the video queue. Zero-copy: stamps DisplayImmediately on
/// the SCK-owned buffer and enqueues it straight into the renderer. Never
/// queues when the renderer is saturated — a queued frame is permanent added
/// latency; a dropped one is invisible at 60 Hz.
final class StreamFrameHandler: NSObject, SCStreamOutput {
    private let renderer: AVSampleBufferVideoRenderer
    private let meter: FrameRateMeter

    init(renderer: AVSampleBufferVideoRenderer, meter: FrameRateMeter) {
        self.renderer = renderer
        self.meter = meter
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }

        switch status {
        case .complete, .started:
            if renderer.requiresFlushToResumeDecoding {
                renderer.flush()
            }
            guard renderer.isReadyForMoreMediaData else {
                meter.countDropped()
                return
            }
            stampDisplayImmediately(sampleBuffer)
            renderer.enqueue(sampleBuffer)
            meter.countFrame()
        case .idle, .blank, .suspended:
            // Layer keeps showing the last frame; count for liveness.
            meter.countIdle()
        default:
            break
        }
    }

    private func stampDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0),
                                 to: CFMutableDictionary.self)
        CFDictionarySetValue(dict,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}
