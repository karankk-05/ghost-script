import Foundation
import CryptoKit
import LicenseCore

final class DeviceIdentity {
    private let key: SecureEnclave.P256.Signing.PrivateKey
    var publicKey: Data { key.publicKey.x963Representation }
    var deviceID: String { OfflineLicense.deviceID(for: publicKey) }

    init() throws {
        guard SecureEnclave.isAvailable else {
            throw NSError(domain: "Activation", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Activation requires an Apple silicon Mac with an available Secure Enclave."])
        }
        try WorkspacePaths.prepare()
        if FileManager.default.fileExists(atPath: WorkspacePaths.deviceKey.path) {
            // Never silently replace a key that cannot be loaded. A copied blob
            // cannot be unwrapped on another Mac, and existing licenses must fail.
            key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: Data(contentsOf: WorkspacePaths.deviceKey))
        } else {
            key = try SecureEnclave.P256.Signing.PrivateKey()
            try WorkspacePaths.savePrivate(key.dataRepresentation, to: WorkspacePaths.deviceKey)
        }
    }
    func request() throws -> DeviceRequest {
        let proof = try key.signature(for: OfflineLicense.requestMessage(for: publicKey))
        return DeviceRequest(publicKey: publicKey, proof: proof.derRepresentation)
    }
    func provePossession() throws {
        // Fresh challenge ensures a copied public key or identifier is insufficient.
        let challenge = Data((UUID().uuidString + UUID().uuidString).utf8)
        let signature = try key.signature(for: challenge)
        guard key.publicKey.isValidSignature(signature, for: challenge) else { throw LicenseFailure.wrongDevice }
    }
}
