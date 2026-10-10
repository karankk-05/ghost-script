import Foundation
import CryptoKit
import LicenseCore

struct CheckFailure: Error { let message: String }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(message: message) }
}
func requireFailure(_ expected: LicenseFailure? = nil, _ operation: () throws -> Void) throws {
    do { try operation() }
    catch {
        if let expected { try require(error as? LicenseFailure == expected, "Expected \(expected), got \(error)") }
        return
    }
    throw CheckFailure(message: "An invalid request or license was accepted")
}
func request() throws -> DeviceRequest {
    let device = P256.Signing.PrivateKey()
    let pub = device.publicKey.x963Representation
    return DeviceRequest(publicKey: pub, proof: try device.signature(for: OfflineLicense.requestMessage(for: pub)).derRepresentation)
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
let checks: [(String, () throws -> Void)] = [
    ("Valid request and license round-trip", {
        let issuer = Curve25519.Signing.PrivateKey(), device = try request()
        try require(try DeviceRequest.parse(device.code()).deviceID == device.deviceID, "Request changed identity")
        let code = try OfflineLicense.issue(request: device, owner: "Recipient", signingKey: issuer, now: now)
        try require(try OfflineLicense.verify(code, authority: issuer.publicKey.rawRepresentation,
            deviceID: device.deviceID, now: now).owner == "Recipient", "Owner changed")
    }),
    ("Copied license rejected on another device", {
        let issuer = Curve25519.Signing.PrivateKey(), device = try request()
        let code = try OfflineLicense.issue(request: device, owner: "Recipient", signingKey: issuer, now: now)
        let other = try request()
        try requireFailure(.wrongDevice) { _ = try OfflineLicense.verify(code,
            authority: issuer.publicKey.rawRepresentation, deviceID: other.deviceID, now: now) }
    }),
    ("Wrong signing authority rejected", {
        let issuer = Curve25519.Signing.PrivateKey(), device = try request()
        let code = try OfflineLicense.issue(request: device, owner: "Recipient", signingKey: issuer, now: now)
        try requireFailure(.invalidSignature) { _ = try OfflineLicense.verify(code,
            authority: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, deviceID: device.deviceID, now: now) }
    }),
    ("Edited license payload rejected", {
        let issuer = Curve25519.Signing.PrivateKey(), device = try request()
        let code = try OfflineLicense.issue(request: device, owner: "Recipient", signingKey: issuer, now: now)
        let envelope = try JSONDecoder().decode(LicenseEnvelope.self,
            from: OfflineLicense.decodeBase64URL(String(code.dropFirst(7)))!)
        let edited = Data(String(data: envelope.payload, encoding: .utf8)!.replacingOccurrences(of: "Recipient", with: "Intruder").utf8)
        let tampered = "FKLIC1." + OfflineLicense.base64URL(try OfflineLicense.encode(LicenseEnvelope(payload: edited, signature: envelope.signature)))
        try requireFailure(.invalidSignature) { _ = try OfflineLicense.verify(tampered,
            authority: issuer.publicKey.rawRepresentation, deviceID: device.deviceID, now: now) }
    }),
    ("Expired and future-dated licenses rejected", {
        let issuer = Curve25519.Signing.PrivateKey(), device = try request()
        let code = try OfflineLicense.issue(request: device, owner: "Recipient", expiresAt: now.addingTimeInterval(3600), signingKey: issuer, now: now)
        try requireFailure(.expired) { _ = try OfflineLicense.verify(code, authority: issuer.publicKey.rawRepresentation,
            deviceID: device.deviceID, now: now.addingTimeInterval(3600)) }
        try requireFailure(.notYetValid) { _ = try OfflineLicense.verify(code, authority: issuer.publicKey.rawRepresentation,
            deviceID: device.deviceID, now: now.addingTimeInterval(-301)) }
    }),
    ("Forged device proof and garbage rejected", {
        let first = try request(), other = try request()
        try requireFailure(.invalidRequest) { try DeviceRequest(publicKey: first.publicKey, proof: other.proof).validate() }
        for code in ["", "password", "FKLIC1.abc", String(repeating: "A", count: 20_000)] {
            try requireFailure { _ = try OfflineLicense.verify(code, authority: Data(), deviceID: "", now: now) }
        }
    }),
    ("Invalid expiry and blank owner cannot be issued", {
        let issuer = Curve25519.Signing.PrivateKey(), device = try request()
        try requireFailure { _ = try OfflineLicense.issue(request: device, owner: "", signingKey: issuer, now: now) }
        try requireFailure { _ = try OfflineLicense.issue(request: device, owner: "Recipient",
            expiresAt: now, signingKey: issuer, now: now) }
    }),
]

do {
    for (name, check) in checks { try check(); print("PASS: \(name)") }
    print("\(checks.count) license checks passed.")
} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
