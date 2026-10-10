import AppKit

@main
@MainActor
struct AppRunner {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let command = arguments.first, command == "--activation-request" || command == "--check-license" || command == "--verify-code" {
            let license = LicenseController()
            do {
                switch command {
                case "--activation-request": print(try license.requestCode())
                case "--verify-code":
                    guard arguments.count == 2 else { throw NSError(domain: "Activation", code: 1) }
                    let code = try String(contentsOfFile: arguments[1], encoding: .utf8)
                    print(try license.verifyCode(code).owner)
                default:
                    guard license.check() else { throw NSError(domain: "Activation", code: 1, userInfo: [NSLocalizedDescriptionKey: license.lastError]) }
                    print("Active: \(license.claims?.owner ?? "")")
                }
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
