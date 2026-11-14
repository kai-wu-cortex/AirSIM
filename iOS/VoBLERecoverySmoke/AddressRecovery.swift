import Foundation
import CryptoKit
import Security

enum VoBLECentralError: Error { case authenticationFailed }
final class MemoryStore: VoBLEPairingStoring, @unchecked Sendable {
    var values: [String: VoBLEStoredPeer] = [:]
    func load(identity: String) throws -> VoBLEStoredPeer? { values[identity] }
    func save(_ peer: VoBLEStoredPeer) throws { values[peer.identity] = peer }
    func revoke(identity: String) throws { values.removeValue(forKey: identity) }
}
@main struct AddressRecoveryChecks {
    static func main() async throws {
        let key = Data(repeating: 1, count: 32), pub = Data(repeating: 2, count: 32)
        let nonce = Data(repeating: 3, count: 32), identity = "recovery-fixture", challenge = "challenge-fixture"
        let message = try VoBLESessionAuthenticator.addressRecoveryMessage(challengeID: challenge,
            identity: identity, androidPublic: pub, androidNonce: nonce)
        let proof = try VoBLESessionAuthenticator.tag(message: message, key: key)
        precondition(proof.map { String(format: "%02x", $0) }.joined() == "ed3246738f539a33794495649c016ab0")
        let store = MemoryStore()
        try store.save(.init(identity: identity, pairingKey: key, createdAt: Date()))
        let worker = VoBLEPairingWorker(store: store)
        for scenario in 0..<6 {
            do {
                let prepared = try await worker.prepare(identity: identity, androidPublic: pub,
                    androidNonce: scenario == 4 ? Data(repeating: 4, count: 32) : nonce,
                    recoveryIdentity: scenario == 1 ? "other-device" : identity,
                    challengeID: scenario == 5 ? "stale-challenge" : challenge,
                    recoveryProof: scenario == 2 ? nil : scenario == 3 ? Data(repeating: 0, count: 16) : proof)
                precondition(scenario == 0 && prepared.reconnectTag != nil)
            } catch { precondition(scenario != 0) }
            let stored = try store.load(identity: identity)
            precondition(stored?.pairingKey == key)
        }
        try store.revoke(identity: identity)
        do {
            _ = try await worker.prepare(identity: identity, androidPublic: pub, androidNonce: nonce,
                recoveryIdentity: identity, challengeID: challenge, recoveryProof: proof)
            preconditionFailure("unknown peer accepted")
        } catch {}
        let legacy = try await worker.prepare(identity: identity, androidPublic: pub, androidNonce: nonce)
        precondition(legacy.reconnectTag == nil, "explicit new pairing must remain available")
        print("PASS: address recovery vector + real pairing worker: valid, wrong identity, absent/forged proof, changed nonce/challenge, missing key, legacy explicit pairing")
    }
}
