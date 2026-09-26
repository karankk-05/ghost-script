import AVFoundation
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayNotFound
    case notRunning

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "The capture source display is no longer available."
        case .notRunning: return "Capture is not running."
        }
    }
}

/// Owns the SCStream: filter building, start/stop, live reconfiguration and
/// didStopWithError mapping. All control on the MainActor; frames never touch
/// it (they flow on videoQueue inside StreamFrameHandler).
@MainActor
final class CaptureEngine: NSObject, SCStreamDelegate {
    // SCStream error codes (SCStreamErrorDomain)
    private static let errUserStopped = -3817
    private static let errSystemStopped = -3821
    private static let errNoPermission = -3801
    private static let transientCodes: Set<Int> = [-3814, -3815]

    private let videoQueue = DispatchQueue(label: "io.koerbaecher.ghostscreen.video",
                                           qos: .userInteractive)
    private(set) lazy var meter = FrameRateMeter(queue: videoQueue)

    private var stream: SCStream?
    private var handler: StreamFrameHandler?
    private var filter: SCContentFilter?
    private var isStopping = false
    private var retriesLeft = 2
    /// Bumped by every start()/stop(); a pending transient-error retry must
    /// observe an unchanged generation or die — otherwise it can resurrect a
    /// stream the user stopped, or double-start next to a newer session.
    private var generation = 0
    private var retryTask: Task<Void, Never>?

    // Remembered for retries and live reconfiguration.
    private var displayID: CGDirectDisplayID = 0
    private var excludedWindowNumbers: [Int] = []
    private var outputPixelSize: CGSize = .zero
    private var outputMaxHz = 60
    private weak var renderer: AVSampleBufferVideoRenderer?

    var onFailure: ((CaptureFailure) -> Void)?

    func start(displayID: CGDirectDisplayID,
               excludingWindowNumbers: [Int],
               renderer: AVSampleBufferVideoRenderer,
               outputPixelSize: CGSize,
               maxHz: Int) async throws {
        await stop()
        generation += 1
        self.displayID = displayID
        self.excludedWindowNumbers = excludingWindowNumbers
        self.outputPixelSize = outputPixelSize
        self.outputMaxHz = maxHz
        self.renderer = renderer
        self.retriesLeft = 2
        try await startStream()
    }

    private func startStream() async throws {
        guard let renderer else { throw CaptureError.notRunning }
        let content = try await SCShareableContent.current // throws -3801 without TCC
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        let excluded = content.windows.filter {
            excludedWindowNumbers.contains(Int($0.windowID))
        }
        let filter = SCContentFilter(display: scDisplay, excludingWindows: excluded)
        let config = CaptureConfigBuilder.makeConfig(filter: filter,
                                                     outputPixelSize: outputPixelSize,
                                                     maxHz: outputMaxHz)
        let handler = StreamFrameHandler(renderer: renderer, meter: meter)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: videoQueue)
        try await stream.startCapture()

        self.filter = filter
        self.handler = handler
        self.stream = stream
        isStopping = false
        meter.start()
    }

    func updateOutput(pixelSize: CGSize, maxHz: Int) async {
        outputPixelSize = pixelSize
        outputMaxHz = maxHz
        guard let stream, let filter else { return }
        let config = CaptureConfigBuilder.makeConfig(filter: filter,
                                                     outputPixelSize: pixelSize,
                                                     maxHz: maxHz)
        try? await stream.updateConfiguration(config)
    }

    func rebuildFilter(excludingWindowNumbers: [Int]) async {
        excludedWindowNumbers = excludingWindowNumbers
        guard let stream else { return }
        guard let content = try? await SCShareableContent.current,
              let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else { return }
        let excluded = content.windows.filter {
            excludedWindowNumbers.contains(Int($0.windowID))
        }
        let filter = SCContentFilter(display: scDisplay, excludingWindows: excluded)
        self.filter = filter
        try? await stream.updateContentFilter(filter)
        let config = CaptureConfigBuilder.makeConfig(filter: filter,
                                                     outputPixelSize: outputPixelSize,
                                                     maxHz: outputMaxHz)
        try? await stream.updateConfiguration(config)
    }

    func stop() async {
        generation += 1
        retryTask?.cancel()
        retryTask = nil
        isStopping = true
        meter.stop()
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        handler = nil
        filter = nil
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        Task { @MainActor in
            self.handleStreamStopped(code: nsError.code, message: nsError.localizedDescription)
        }
    }

    private func handleStreamStopped(code: Int, message: String) {
        guard !isStopping else { return }
        meter.stop()
        stream = nil

        switch code {
        case Self.errUserStopped:
            onFailure?(.stopped(reason: "Capture was stopped from the system sharing indicator."))
        case Self.errSystemStopped:
            onFailure?(.stopped(reason: "macOS stopped the capture."))
        case Self.errNoPermission:
            onFailure?(.permissionDenied)
        case _ where Self.transientCodes.contains(code) && retriesLeft > 0:
            retriesLeft -= 1
            let gen = generation
            retryTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                // A stop() or newer start() during the sleep owns the stream
                // now — resurrecting it here would capture headless.
                guard !Task.isCancelled, gen == self.generation, !self.isStopping else { return }
                do { try await self.startStream() } catch {
                    self.onFailure?(.failed("Restart after transient error failed: \(error.localizedDescription)"))
                }
            }
        default:
            onFailure?(.failed(message))
        }
    }
}
