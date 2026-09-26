// Spike D — does stamping kCMSampleAttachmentKey_DisplayImmediately on
// SCK-owned sample buffers actually render through AVSampleBufferDisplayLayer's
// sampleBufferRenderer, at a steady cadence?
//
// Renders a live capture of the built-in display into a small window for ~6s
// (the render window itself excluded from the capture to avoid the infinite
// mirror), logging per-second frame counts, inter-frame jitter, drops, and
// renderer failures. Judder is ultimately a human judgment; this validates the
// mechanism and prints the numbers.

import AppKit
import AVFoundation
import ScreenCaptureKit

final class RenderView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(displayLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class FrameSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let renderer: AVSampleBufferVideoRenderer
    private var lastArrival: CFTimeInterval?
    // stats guarded by the serial sampleHandlerQueue
    var received = 0, enqueued = 0, dropped = 0, idle = 0
    var jitterMax: Double = 0
    var perSecond: [Int] = []
    private var windowCount = 0
    private var windowStart = CACurrentMediaTime()

    init(renderer: AVSampleBufferVideoRenderer) { self.renderer = renderer }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw) else { return }
        switch status {
        case .complete, .started:
            received += 1
            let now = CACurrentMediaTime()
            if let last = lastArrival { jitterMax = max(jitterMax, abs((now - last) - 1.0 / 60.0)) }
            lastArrival = now
            windowCount += 1
            if now - windowStart >= 1.0 { perSecond.append(windowCount); windowCount = 0; windowStart = now }

            guard renderer.isReadyForMoreMediaData else { dropped += 1; return }
            // The mutation under test: mark the SCK-owned buffer display-immediately.
            if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [CFMutableDictionary],
               let first = arr.first {
                CFDictionarySetValue(first,
                                     Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            renderer.enqueue(sb)
            enqueued += 1
        case .idle, .blank, .suspended:
            idle += 1
        default:
            break
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("stream stopped: \(error)\n", stderr)
    }
}

@MainActor
func run() async throws {
    guard CGPreflightScreenCaptureAccess() else {
        print("NO SCREEN RECORDING PERMISSION — requesting; grant and re-run.")
        CGRequestScreenCaptureAccess()
        exit(2)
    }
    let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 400),
                       styleMask: [.titled], backing: .buffered, defer: false)
    win.title = "spike-pacing"
    let view = RenderView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    win.contentView = view
    win.orderFrontRegardless()
    try await Task.sleep(nanoseconds: 500_000_000)

    let content = try await SCShareableContent.current
    guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 })
            ?? content.displays.first else { fatalError("no display") }
    let excluded = content.windows.filter { $0.windowID == CGWindowID(win.windowNumber) }

    let cfg = SCStreamConfiguration()
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    cfg.width = Int(CGFloat(display.width) * scale)
    cfg.height = Int(CGFloat(display.height) * scale)
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    cfg.queueDepth = 5
    cfg.showsCursor = true

    let sink = FrameSink(renderer: view.displayLayer.sampleBufferRenderer)
    let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: excluded),
                          configuration: cfg, delegate: sink)
    try stream.addStreamOutput(sink, type: .screen,
                               sampleHandlerQueue: DispatchQueue(label: "spike.video", qos: .userInteractive))
    try await stream.startCapture()
    print("capturing for 6s — move a window around to generate motion…")
    try await Task.sleep(nanoseconds: 6_000_000_000)
    try await stream.stopCapture()

    print("\n=== SPIKE D RESULTS ===")
    print("received=\(sink.received) enqueued=\(sink.enqueued) dropped=\(sink.dropped) idle=\(sink.idle)")
    print("fps per second: \(sink.perSecond)")
    print(String(format: "max inter-frame jitter vs 60Hz ideal: %.1f ms", sink.jitterMax * 1000))
    if view.displayLayer.status == .failed {
        print("RENDERER FAILED: \(String(describing: view.displayLayer.error))")
        exit(1)
    }
    let rendered = sink.enqueued > 60 && view.displayLayer.status != .failed
    print(rendered ? "RESULT: PASS — DisplayImmediately buffers render" : "RESULT: FAIL")
    exit(rendered ? 0 : 1)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run() } catch { fputs("SPIKE D ERROR: \(error)\n", stderr); exit(1) }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
