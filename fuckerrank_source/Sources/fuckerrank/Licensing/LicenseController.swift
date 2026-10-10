import Foundation
import CryptoKit
import LicenseCore

@MainActor
final class LicenseController {
    private var identity: DeviceIdentity?
    private var initializationError: Error?
    private(set) var claims: LicenseClaims?
    private(set) var lastError = "Activation is required on this Mac."

    init() {
        do { identity = try DeviceIdentity() }
        catch { initializationError = error; lastError = error.localizedDescription }
    }
    func requestCode() throws -> String {
        if let initializationError { throw initializationError }
        guard let identity else { throw LicenseFailure.invalidRequest }
        return try identity.request().code()
    }
    func check() -> Bool {
        do {
            let code = try String(contentsOf: WorkspacePaths.license, encoding: .utf8)
            claims = try validate(code)
            lastError = ""
            return true
        } catch {
            claims = nil
            lastError = FileManager.default.fileExists(atPath: WorkspacePaths.license.path)
                ? error.localizedDescription : (initializationError?.localizedDescription ?? "Activation is required on this Mac.")
            return false
        }
    }
    func activate(_ code: String) throws {
        let validated = try validate(code)
        try WorkspacePaths.savePrivate(Data(code.trimmingCharacters(in: .whitespacesAndNewlines).utf8), to: WorkspacePaths.license)
        claims = validated; lastError = ""
    }
    func verifyCode(_ code: String) throws -> LicenseClaims { try validate(code) }
    private func validate(_ code: String) throws -> LicenseClaims {
        if let initializationError { throw initializationError }
        guard let identity, let authority = Data(base64Encoded: LicenseAuthority.publicKeyBase64), authority.count == 32 else {
            throw NSError(domain: "Activation", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "This build is missing its license authority. Ask the owner for a correctly packaged app."])
        }
        try identity.provePossession()
        return try OfflineLicense.verify(code, authority: authority, deviceID: identity.deviceID)
    }
}
