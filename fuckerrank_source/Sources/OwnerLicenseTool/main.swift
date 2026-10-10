import AppKit
import CryptoKit
import LicenseCore

enum Issuer {
    static var keyURL: URL {
        if let path = ProcessInfo.processInfo.environment["FUCKERRANK_ISSUER_KEY"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("issuer.key")
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("issuer.key")
    }
    static var directory: URL { keyURL.deletingLastPathComponent() }
    static func key(create: Bool = false) throws -> Curve25519.Signing.PrivateKey {
        if FileManager.default.fileExists(atPath: keyURL.path) {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyURL))
        }
        guard create else {
            throw NSError(domain: "LicenseTool", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Owner key is missing. Restore your backup of \(keyURL.path)."])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let key = Curve25519.Signing.PrivateKey()
        // Exclusive creation avoids replacing an existing signing identity.
        let fd = Darwin.open(keyURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: key.rawRepresentation)
        try handle.close()
        return key
    }
    static func expiry(_ text: String) throws -> Date? {
        if text.isEmpty { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else {
            throw NSError(domain: "LicenseTool", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Use YYYY-MM-DD for expiry, or leave it empty."])
        }
        return date // Exclusive expiry at 00:00 UTC on the chosen date.
    }
}

@MainActor
final class OwnerWindow: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let request = NSTextView()
    let name = NSTextField(string: "")
    let expires = NSTextField(string: "")
    let output = NSTextView()
    let message = NSTextField(wrappingLabelWithString: "Keep this app and the signing key on your own Mac. Share only the recipient installer and their activation code.")
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "fuckerrank License Manager — Owner Only"
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        stack.addArrangedSubview(message)
        stack.addArrangedSubview(NSTextField(labelWithString: "1. Paste the recipient's activation request"))
        stack.addArrangedSubview(scroll(request, height: 120))
        name.placeholderString = "Recipient's name (required)"
        expires.placeholderString = "Optional expiry: YYYY-MM-DD (00:00 UTC)"
        for field in [name, expires, message] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 590).isActive = true
        }
        stack.addArrangedSubview(name); stack.addArrangedSubview(expires)
        let generate = NSButton(title: "Generate Activation Code", target: self, action: #selector(generateCode))
        stack.addArrangedSubview(generate)
        stack.addArrangedSubview(NSTextField(labelWithString: "2. Copy this code into their app"))
        output.isEditable = false
        stack.addArrangedSubview(scroll(output, height: 120))
        stack.addArrangedSubview(NSButton(title: "Copy Activation Code", target: self, action: #selector(copyCode)))
        window.contentView = stack
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func scroll(_ text: NSTextView, height: CGFloat) -> NSScrollView {
        text.isRichText = false; text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        let view = NSScrollView(); view.hasVerticalScroller = true; view.borderType = .bezelBorder
        view.documentView = text
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 590).isActive = true
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        return view
    }
    @objc private func generateCode() {
        do {
            output.string = try OfflineLicense.issue(request: DeviceRequest.parse(request.string),
                owner: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                expiresAt: Issuer.expiry(expires.stringValue), signingKey: Issuer.key())
            message.stringValue = "Code generated for this Mac only. Expiry is optional; no server is contacted."
        } catch { output.string = ""; message.stringValue = error.localizedDescription }
    }
    @objc private func copyCode() {
        guard !output.string.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output.string, forType: .string)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if !arguments.isEmpty {
    do {
        switch arguments[0] {
        case "init-key":
            let key = try Issuer.key(create: true)
            print(key.publicKey.rawRepresentation.base64EncodedString())
        case "public-key": print(try Issuer.key().publicKey.rawRepresentation.base64EncodedString())
        case "issue":
            guard arguments.count == 3 || arguments.count == 4 else {
                throw NSError(domain: "LicenseTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "Usage: OwnerLicenseTool issue REQUEST_FILE OWNER [YYYY-MM-DD]"])
            }
            let request = try DeviceRequest.parse(String(contentsOfFile: arguments[1], encoding: .utf8))
            print(try OfflineLicense.issue(request: request, owner: arguments[2],
                expiresAt: Issuer.expiry(arguments.count == 4 ? arguments[3] : ""), signingKey: Issuer.key()))
        default: throw NSError(domain: "LicenseTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "Commands: init-key, public-key, issue REQUEST_FILE OWNER [YYYY-MM-DD]"])
        }
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    let delegate = OwnerWindow()
    app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
}
