import CryptoKit
import Foundation

struct SamsungPairingSealedPayload {
    let clientPublicKey: Data
    let combined: Data
}

enum SamsungPairingCrypto {
    static func seal(
        registration: Data,
        serverPublicKey: Data,
        sessionID: String,
        code: String,
        privateKey privateKeyData: Data? = nil,
        nonce nonceData: Data? = nil
    ) throws -> SamsungPairingSealedPayload {
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        if let privateKeyData {
            privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
        } else {
            privateKey = Curve25519.KeyAgreement.PrivateKey()
        }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(sessionID.utf8),
            sharedInfo: Data("AirSIMPair/v1:\(code)".utf8),
            outputByteCount: 32
        )
        let box: AES.GCM.SealedBox
        if let nonceData {
            box = try AES.GCM.seal(
                registration,
                using: key,
                nonce: try AES.GCM.Nonce(data: nonceData),
                authenticating: Data(sessionID.utf8)
            )
        } else {
            box = try AES.GCM.seal(
                registration,
                using: key,
                authenticating: Data(sessionID.utf8)
            )
        }
        guard let combined = box.combined else {
            throw SamsungPairingError.invalidEncryptedPayload
        }
        return SamsungPairingSealedPayload(
            clientPublicKey: privateKey.publicKey.rawRepresentation,
            combined: combined
        )
    }
}

enum SamsungPairingError: LocalizedError {
    case invalidEncryptedPayload

    var errorDescription: String? {
        switch self {
        case .invalidEncryptedPayload:
            return "无法生成配对加密数据"
        }
    }
}
