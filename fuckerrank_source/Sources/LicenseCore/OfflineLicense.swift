import Foundation
import CryptoKit

public enum LicenseFailure: LocalizedError, Equatable {
    case invalidRequest, invalidCode, invalidSignature, wrongDevice, wrongProduct, expired, notYetValid
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "The activation request is invalid. Copy the complete request from the recipient's Mac."
        case .invalidCode: return "The activation code is invalid. Paste the complete code."
        case .invalidSignature: return "This activation code was not signed by your app's owner."
        case .wrongDevice: return "This activation code belongs to a different Mac."
        case .wrongProduct: return "This activation code belongs to a different application."
        case .expired: return "This license has expired. Contact the owner for a renewal."
        case .notYetValid: return "The Mac's date is earlier than the license's issue date. Check Date & Time settings."
        }
    }
}

public enum OfflineLicense {
    public static let product = "io.karan.fuckerrank"
    public static func deviceID(for publicKey: Data) -> String {
        SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    }
    public static func requestMessage(for publicKey: Data) -> Data {
        Data(("fuckerrank:request:v1:" + publicKey.base64EncodedString()).utf8)
    }
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func decodeBase64URL(_ value: String) -> Data? {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)
    }
    public static func issue(request: DeviceRequest, owner: String, expiresAt: Date? = nil,
                             signingKey: Curve25519.Signing.PrivateKey, now: Date = Date()) throws -> String {
        try request.validate()
        guard !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, owner.count <= 200,
              expiresAt.map({ $0 > now }) ?? true else { throw LicenseFailure.invalidCode }
        let claims = LicenseClaims(version: 1, product: product, deviceID: request.deviceID,
            licenseID: UUID().uuidString, owner: owner, issuedAt: now.timeIntervalSince1970,
            expiresAt: expiresAt?.timeIntervalSince1970)
        let payload = try encode(claims)
        let envelope = LicenseEnvelope(payload: payload, signature: try signingKey.signature(for: payload))
        return "FKLIC1." + base64URL(try encode(envelope))
    }
    public static func verify(_ code: String, authority: Data, deviceID: String,
                              now: Date = Date()) throws -> LicenseClaims {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 16_384, text.hasPrefix("FKLIC1."),
              let data = decodeBase64URL(String(text.dropFirst(7))),
              let envelope = try? JSONDecoder().decode(LicenseEnvelope.self, from: data) else {
            throw LicenseFailure.invalidCode
        }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: authority),
              key.isValidSignature(envelope.signature, for: envelope.payload) else {
            throw LicenseFailure.invalidSignature
        }
        let claims = try JSONDecoder().decode(LicenseClaims.self, from: envelope.payload)
        guard claims.version == 1, claims.product == product else { throw LicenseFailure.wrongProduct }
        guard claims.deviceID == deviceID else { throw LicenseFailure.wrongDevice }
        guard claims.issuedAt.isFinite, !claims.owner.isEmpty, claims.owner.count <= 200,
              UUID(uuidString: claims.licenseID) != nil,
              claims.expiresAt.map({ $0.isFinite && $0 > claims.issuedAt }) ?? true else {
            throw LicenseFailure.invalidCode
        }
        guard now.timeIntervalSince1970 >= claims.issuedAt - 300 else { throw LicenseFailure.notYetValid }
        if let expiry = claims.expiresAt, now.timeIntervalSince1970 >= expiry { throw LicenseFailure.expired }
        return claims
    }
}

public struct DeviceRequest: Codable, Sendable {
    public let version: Int
    public let product: String
    public let publicKey: Data
    public let proof: Data
    public var deviceID: String { OfflineLicense.deviceID(for: publicKey) }
    public init(publicKey: Data, proof: Data) {
        version = 1; product = OfflineLicense.product; self.publicKey = publicKey; self.proof = proof
    }
    public func validate() throws {
        guard version == 1, product == OfflineLicense.product,
              let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: proof),
              key.isValidSignature(signature, for: OfflineLicense.requestMessage(for: publicKey)) else {
            throw LicenseFailure.invalidRequest
        }
    }
    public func code() throws -> String {
        try validate()
        return "FKREQ1." + OfflineLicense.base64URL(try OfflineLicense.encode(self))
    }
    public static func parse(_ code: String) throws -> DeviceRequest {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 4096, text.hasPrefix("FKREQ1."),
              let data = OfflineLicense.decodeBase64URL(String(text.dropFirst(7))),
              let request = try? JSONDecoder().decode(Self.self, from: data) else {
            throw LicenseFailure.invalidRequest
        }
        try request.validate()
        return request
    }
}

public struct LicenseClaims: Codable, Sendable {
    public let version: Int
    public let product: String
    public let deviceID: String
    public let licenseID: String
    public let owner: String
    public let issuedAt: Double
    public let expiresAt: Double?
}

public struct LicenseEnvelope: Codable, Sendable {
    public let payload: Data
    public let signature: Data
    public init(payload: Data, signature: Data) { self.payload = payload; self.signature = signature }
}
