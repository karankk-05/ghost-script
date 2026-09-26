// Spike A — the existential premise check.
//
// Question: is a window with NSWindow.sharingType = .none absent from a
// ScreenCaptureKit display capture, with the content BEHIND it cleanly
// recomposited (not a black box)? And does SCContentFilter(display:excludingWindows:)
// behave the same as the explicit fallback?
//
// Method: put a solid GREEN backdrop window (normal sharing) on the built-in
// display, and a solid MAGENTA test window fully inside it, one level above.
// Capture the display three ways and classify the pixels at the magenta rect:
//   pass 1 "protected":  magenta.sharingType = .none,     excludingWindows: []
//   pass 2 "excluded":   magenta.sharingType = .readOnly, excludingWindows: [magenta]
//   pass 3 "control":    magenta.sharingType = .readOnly, excludingWindows: []
// Expected: 1 → GREEN (premise holds), 2 → GREEN (fallback holds), 3 → MAGENTA
// (proves the harness would have seen the window). Pass 1 is additionally
// repeated through a real SCStream (not just SCScreenshotManager).
//
// PNGs land in Spikes/out/ as evidence.

import AppKit
import ScreenCaptureKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let outDir: URL = {
    let src = URL(fileURLWithPath: #filePath) // .../Spikes/Sources/spike-capture-exclusion/main.swift
    return src.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("out", isDirectory: true)
}()

// Backdrop rect and test rect (screen points, bottom-left origin, built-in display).
let greenFrame = NSRect(x: 400, y: 300, width: 800, height: 600)
let magentaFrame = NSRect(x: 600, y: 400, width: 400, height: 300)

@MainActor
func makeWindow(frame: NSRect, color: NSColor, level: NSWindow.Level) -> NSWindow {
    let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    w.backgroundColor = color
    w.isOpaque = true
    w.hasShadow = false
    w.level = level
    w.ignoresMouseEvents = true
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    w.orderFrontRegardless()
    return w
}

func writePNG(_ image: CGImage, name: String) throws {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let url = outDir.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw SpikeError.io("CGImageDestination for \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw SpikeError.io("finalize \(url.path)") }
    print("  wrote \(url.path)")
}

enum SpikeError: Error { case io(String), capture(String) }

// Average RGB (0–1) over a region of the image, via a known-format RGBA8 context.
func averageColor(of image: CGImage, region: CGRect) -> (r: Double, g: Double, b: Double)? {
    guard let cropped = image.cropping(to: region) else { return nil }
    let w = cropped.width, h = cropped.height
    guard w > 0, h > 0 else { return nil }
    var data = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
    var r = 0.0, g = 0.0, b = 0.0
    for i in stride(from: 0, to: data.count, by: 4) {
        r += Double(data[i]); g += Double(data[i + 1]); b += Double(data[i + 2])
    }
    let n = Double(w * h) * 255.0
    return (r / n, g / n, b / n)
}

func classify(_ c: (r: Double, g: Double, b: Double)) -> String {
    if c.r > 0.7 && c.b > 0.7 && c.g < 0.35 { return "MAGENTA (window visible)" }
    if c.g > 0.55 && c.r < 0.45 && c.b < 0.45 { return "GREEN (clean recomposite)" }
    if c.r < 0.12 && c.g < 0.12 && c.b < 0.12 { return "BLACK BOX" }
    return "OTHER"
}

// Screen-points rect (bottom-left origin) → image-pixels rect (top-left origin).
func imageRegion(for pointsRect: NSRect, displayHeightPts: CGFloat, scale: CGFloat) -> CGRect {
    // Sample the central half of the rect to stay clear of edges/shadows.
    let inset = pointsRect.insetBy(dx: pointsRect.width / 4, dy: pointsRect.height / 4)
    return CGRect(x: inset.origin.x * scale,
                  y: (displayHeightPts - inset.origin.y - inset.height) * scale,
                  width: inset.width * scale,
                  height: inset.height * scale)
}

// Grab exactly one .complete frame from an SCStream.
final class OneFrameGrabber: NSObject, SCStreamOutput, SCStreamDelegate {
    private let onFrame: @Sendable (CVPixelBuffer) -> Void
    private let done = NSLock()
    private var fired = false
    init(onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) { self.onFrame = onFrame }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        done.lock(); defer { done.unlock() }
        guard !fired else { return }
        fired = true
        onFrame(pb)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("stream stopped: \(error)\n", stderr)
    }
}

@MainActor
func runSpike() async throws {
    guard CGPreflightScreenCaptureAccess() else {
        print("NO SCREEN RECORDING PERMISSION — requesting (grant in System Settings, then re-run).")
        CGRequestScreenCaptureAccess()
        exit(2)
    }

    let green = makeWindow(frame: greenFrame, color: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
                           level: .floating)
    let magenta = makeWindow(frame: magentaFrame, color: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1),
                             level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1))
    _ = green // kept alive by the run loop; silence unused warning

    // Let the compositor settle.
    try await Task.sleep(nanoseconds: 700_000_000)

    let content = try await SCShareableContent.current
    guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 })
            ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
        throw SpikeError.capture("no built-in/main display in shareable content")
    }
    guard let scMagenta = content.windows.first(where: { $0.windowID == CGWindowID(magenta.windowNumber) }) else {
        // Expected for a sharingType=.none window? Re-fetch after making it capturable below if needed.
        print("note: magenta window not in shareable content yet (sharingType default at launch is normal)")
        throw SpikeError.capture("magenta window not found in SCShareableContent")
    }

    let displayHeightPts = CGDisplayBounds(display.displayID).height
    let scale = CGFloat(display.width) > 0
        ? CGFloat(NSScreen.main?.backingScaleFactor ?? 2.0)
        : 2.0
    let cfg = SCStreamConfiguration()
    cfg.width = Int(CGFloat(display.width) * scale)
    cfg.height = Int(CGFloat(display.height) * scale)
    cfg.showsCursor = false
    let region = imageRegion(for: magentaFrame, displayHeightPts: displayHeightPts, scale: scale)

    var verdicts: [(String, String)] = []

    func screenshotPass(_ name: String, filter: SCContentFilter) async throws {
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        try writePNG(img, name: "capture-\(name).png")
        // Screenshot pixel size can differ from cfg; rescale region to actual image size.
        let sx = CGFloat(img.width) / CGFloat(cfg.width), sy = CGFloat(img.height) / CGFloat(cfg.height)
        let scaled = CGRect(x: region.origin.x * sx, y: region.origin.y * sy,
                            width: region.width * sx, height: region.height * sy)
        if let cropped = img.cropping(to: scaled) { try writePNG(cropped, name: "sample-\(name).png") }
        guard let avg = averageColor(of: img, region: scaled) else { throw SpikeError.capture("sampling \(name)") }
        let verdict = classify(avg)
        verdicts.append((name, verdict))
        print(String(format: "  [%@] avg RGB = (%.2f, %.2f, %.2f) → %@", name, avg.r, avg.g, avg.b, verdict))
    }

    // Pass 0 — control FIRST, while sharingType is still the pristine default:
    // the capture MUST show magenta or the harness is broken.
    print("pass 0: control (default sharing, excludingWindows: [])")
    try await screenshotPass("control", filter: SCContentFilter(display: display, excludingWindows: []))

    // Pass 1 — protected: sharingType = .none, no explicit exclusion.
    magenta.sharingType = .none
    try await Task.sleep(nanoseconds: 800_000_000)
    print("pass 1: protected (sharingType=.none, excludingWindows: [])")
    try await screenshotPass("protected", filter: SCContentFilter(display: display, excludingWindows: []))

    // Pass 1b — same premise through a real SCStream.
    print("pass 1b: protected via SCStream")
    let streamCfg = SCStreamConfiguration()
    streamCfg.width = cfg.width; streamCfg.height = cfg.height
    streamCfg.pixelFormat = kCVPixelFormatType_32BGRA
    streamCfg.showsCursor = false
    streamCfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    streamCfg.queueDepth = 3
    let streamImage: CGImage = try await withCheckedThrowingContinuation { cont in
        let holder = ContinuationHolder(cont)
        let grabber = OneFrameGrabber { pb in
            let ci = CIImage(cvPixelBuffer: pb)
            if let cg = CIContext().createCGImage(ci, from: ci.extent) { holder.resume(.success(cg)) }
            else { holder.resume(.failure(SpikeError.capture("CVPixelBuffer→CGImage"))) }
        }
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: streamCfg, delegate: grabber)
        do {
            try stream.addStreamOutput(grabber, type: .screen,
                                       sampleHandlerQueue: DispatchQueue(label: "spike.video"))
        } catch { holder.resume(.failure(error)); return }
        stream.startCapture { err in if let err { holder.resume(.failure(err)) } }
        holder.retain(stream, grabber)
    }
    try writePNG(streamImage, name: "capture-protected-scstream.png")
    if let avg = averageColor(of: streamImage, region: region) {
        let verdict = classify(avg)
        verdicts.append(("protected-scstream", verdict))
        print(String(format: "  [protected-scstream] avg RGB = (%.2f, %.2f, %.2f) → %@", avg.r, avg.g, avg.b, verdict))
    }

    // Pass 2 — excluded: normal sharing, explicit excludingWindows.
    magenta.sharingType = .readOnly
    try await Task.sleep(nanoseconds: 800_000_000)
    print("pass 2: excluded (sharingType=.readOnly, excludingWindows: [magenta])")
    try await screenshotPass("excluded", filter: SCContentFilter(display: display, excludingWindows: [scMagenta]))

    print("\n=== SPIKE A VERDICTS ===")
    for (name, v) in verdicts { print("  \(name): \(v)") }
    let byName = Dictionary(uniqueKeysWithValues: verdicts)
    let pass = byName["protected"]?.hasPrefix("GREEN") == true
        && byName["protected-scstream"]?.hasPrefix("GREEN") == true
        && byName["excluded"]?.hasPrefix("GREEN") == true
        && byName["control"]?.hasPrefix("MAGENTA") == true
    print(pass ? "RESULT: PASS — premise holds" : "RESULT: FAIL/PARTIAL — inspect PNGs")
    exit(pass ? 0 : 1)
}

// Wraps a continuation so competing callbacks can only resume it once,
// and keeps the stream/grabber alive until then.
final class ContinuationHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<CGImage, Error>?
    private var retained: [AnyObject] = []
    init(_ c: CheckedContinuation<CGImage, Error>) { cont = c }
    func retain(_ objects: AnyObject...) { lock.lock(); retained.append(contentsOf: objects); lock.unlock() }
    func resume(_ result: Result<CGImage, Error>) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(with: result)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await runSpike() } catch {
                fputs("SPIKE A ERROR: \(error)\n", stderr)
                exit(1)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
