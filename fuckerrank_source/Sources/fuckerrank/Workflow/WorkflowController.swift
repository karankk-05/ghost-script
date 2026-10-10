import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class WorkflowController {
    private unowned let app: AppDelegate
    private(set) var isBusy = false
    private var activeProcess: Process?
    private var cancelled = false

    init(app: AppDelegate) { self.app = app }
    func perform(_ action: WorkflowAction) {
        guard app.requireLicense() else { return }
        switch action {
        case .screenshot: Task { await takeScreenshot() }
        case .solve: Task { await solve(fast: false) }
        case .flash: Task { await solve(fast: true) }
        case .notes:
            if app.state.notesURL != WorkspacePaths.notes { app.documents.open(url: WorkspacePaths.notes, revealOverlay: false) }
            app.state.overlayVisible.toggle()
        case .theme:
            let next = app.state.theme == "black" ? "white" : (app.state.theme == "white" ? "green" : "black")
            app.state.theme = next; app.promptWindow.setTheme(next)
        case .prompt: app.promptWindow.toggle()
        }
    }
    func cancel() {
        cancelled = true
        if let activeProcess, activeProcess.isRunning { activeProcess.terminate() }
        app.indicator.setIndicator(color: "off")
    }
    private func takeScreenshot() async {
        do {
            guard CGPreflightScreenCaptureAccess() else {
                CGRequestScreenCaptureAccess()
                throw failure("Allow fuckerrank in System Settings → Privacy & Security → Screen Recording, then quit and reopen the app.")
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let mainID = (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
                throw failure("No display is available to capture.")
            }
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let config = SCStreamConfiguration()
            config.width = CGDisplayPixelsWide(display.displayID)
            config.height = CGDisplayPixelsHigh(display.displayID)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard app.requireLicense() else { return }
            let file = WorkspacePaths.screenshots.appendingPathComponent("meet_note_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8)).png")
            guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw failure("The screenshot could not be saved.")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw failure("The screenshot could not be saved.") }
            app.indicator.setIndicator(color: "green")
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !isBusy { app.indicator.setIndicator(color: "off") }
            else { app.indicator.setIndicator(color: "yellow") }
        } catch { app.report(error) }
    }
    private func solve(fast: Bool) async {
        guard !isBusy else { return }
        guard let executable = DependencyInstaller.existingCLI else { app.showSetup(); return }
        isBusy = true; cancelled = false
        app.indicator.setIndicator(color: "yellow")
        defer { isBusy = false; activeProcess = nil; app.indicator.setIndicator(color: "off") }
        do {
            app.promptWindow.save()
            let files = try FileManager.default.contentsOfDirectory(at: WorkspacePaths.screenshots,
                includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.lowercased() == "png" }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            let custom = ((try? String(contentsOf: WorkspacePaths.prompt, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !files.isEmpty || (!custom.isEmpty && custom.lowercased() != "cpp") else {
                throw failure("Take a screenshot first, or enter a question in the prompt window.")
            }
            let prompt = Self.makePrompt(custom: custom, fast: fast)
            // Relative attachment paths contain no spaces, irrespective of the user's home path.
            let attachments = files.map { "@ss/" + $0.lastPathComponent }.joined(separator: " ")
            let model = UserDefaults.standard.string(forKey: fast ? "flashModel" : "solveModel")
                ?? (fast ? "gemini-3.8-flash" : "gemini-3.1-pro")
            let result = try await ProcessRunner.run(executable, arguments: [
                "--model", model, "--effort", fast ? "low" : "high",
                "--mode", "plan", "--sandbox", "--disable-slash-commands", "--print-timeout", "10m",
                "-p", prompt + (attachments.isEmpty ? "" : "\n\n" + attachments)
            ], directory: WorkspacePaths.root, onLaunch: { [weak self] in self?.activeProcess = $0 })
            guard !cancelled, app.requireLicense() else { return }
            guard result.status == 0 else {
                throw failure("Antigravity could not complete the request. Open Setup to sign in or check the model.\n\n" + String(result.error.suffix(2000)))
            }
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { throw failure("Antigravity returned an empty answer. Your screenshots have been kept.") }
            try (output + "\n").write(to: WorkspacePaths.notes, atomically: true, encoding: .utf8)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string)
            // Only archive the files in this request, and only after saving the answer.
            for file in files {
                try FileManager.default.moveItem(at: file, to: WorkspacePaths.archive.appendingPathComponent(file.lastPathComponent))
            }
        } catch { if !cancelled { app.report(error) } }
    }
    private static func makePrompt(custom: String, fast: Bool) -> String {
        let followup = """
        This is a follow-up question. If the images show failing tests or compilation errors, identify the exact mistakes, line numbers, and minimal corrections. Do not rewrite all the code. For a general query, answer concisely. Output plain text only, without markdown fences or conversational filler. Do not run commands or modify files.
        """
        if !custom.isEmpty, custom.lowercased() != "cpp" { return followup + "\n\nUser's follow-up: " + custom }
        if fast { return "Solve the multiple-choice question in the attached images. There can be multiple correct answers. Output only the correct option letters, with no explanation. Do not run commands or modify files." }
        return """
        These images together form a single question, possibly showing different scrolled parts. Give the optimal solution, handle edge cases, and avoid time limit errors. For a multiple-choice question, output only the correct option letters; multiple answers may be correct. For coding questions, prefer C++ unless another language is requested, and use the exact class/function template shown. Output only raw code without markdown fences, comments, explanations, or filler. Use short but intuitive variable names. Do not run commands or modify files.
        """
    }
    private func failure(_ text: String) -> Error {
        NSError(domain: "fuckerrank", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
