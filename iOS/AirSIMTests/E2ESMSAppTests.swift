import CryptoKit
import Network
import XCTest
@testable import AirSIM

/// App-side end-to-end encrypted SMS (issue #24): pairing negotiation and SMS push handling.
final class E2ESMSAppTests: XCTestCase {
    func testTXTAdvertisesE2E() throws {
        let endpoint = NWEndpoint.hostPort(host: "192.168.49.1", port: 38000)
        let base = ["v": "1", "session": "fixture-session",
                    "key": Data(repeating: 1, count: 32).base64EncodedString(),
                    "expires": String(Int(Date().addingTimeInterval(120).timeIntervalSince1970 * 1000))]
        func service(_ extra: [String: String]) -> SamsungPairingService? {
            SamsungPairingBrowser.service(endpoint: endpoint, record: NWTXTRecord(base.merging(extra) { $1 }))
        }
        XCTAssertTrue(try XCTUnwrap(service(["e2e": "1"])).supportsE2ESMS)
        XCTAssertFalse(try XCTUnwrap(service([:])).supportsE2ESMS)
        XCTAssertFalse(try XCTUnwrap(service(["e2e": "0"])).supportsE2ESMS)
        XCTAssertNil(service(["v": "2", "e2e": "1"]))
    }

    func testRelayHealthCapabilities() {
        func body(_ capabilities: String?, service: String = "airsim-push-relay") -> Data {
            var json = #"{"ok":true,"service":""# + service + #"","version":"0.2.1""#
            if let capabilities { json += #","capabilities":"# + capabilities }
            return Data((json + "}").utf8)
        }
        let merged = #"{"agent_command_routing":1,"e2e_sms":1}"#
        XCTAssertTrue(RelayHealthValidation.supportsE2ESMS(statusCode: 200, data: body(merged)))
        XCTAssertFalse(RelayHealthValidation.supportsE2ESMS(statusCode: 200, data: body(nil)))
        XCTAssertFalse(RelayHealthValidation.supportsE2ESMS(statusCode: 200, data: body(#"{"e2e_sms":0}"#)))
        XCTAssertFalse(RelayHealthValidation.supportsE2ESMS(statusCode: 200, data: body(#"{"e2e_sms":"1"}"#)))
        XCTAssertFalse(RelayHealthValidation.supportsE2ESMS(statusCode: 200, data: body(merged, service: "djonehub")))
        XCTAssertFalse(RelayHealthValidation.supportsE2ESMS(statusCode: 503, data: body(merged)))
        // An odd capabilities value must not break the existing Relay identity check.
        XCTAssertEqual(RelayHealthValidation.version(statusCode: 200, data: body("[1]")), "0.2.1")
    }

    func testOfferNeedsCloudRelayAndKeychain() {
        for localOnly in [false, true] {
            for relay in [false, true] {
                for keychain in [false, true] {
                    XCTAssertEqual(E2EPairingPolicy.offer(localOnly: localOnly, relaySupports: relay, keychainReady: keychain),
                                   (localOnly, relay, keychain) == (false, true, true), "\(localOnly) \(relay) \(keychain)")
                }
            }
        }
    }

    func testKeyChangeAfterPairing() {
        let key = SymmetricKey(data: Data(repeating: 9, count: 32))
        XCTAssertNil(E2EPairingKeyChange.after(localOnly: true, sentKey: key, deviceID: "iphone-air"))
        XCTAssertNil(E2EPairingKeyChange.after(localOnly: true, sentKey: nil, deviceID: "iphone-air"))
        XCTAssertEqual(E2EPairingKeyChange.after(localOnly: false, sentKey: key, deviceID: "iphone-air"),
                       .save(E2EKeyRecord(key: Data(repeating: 9, count: 32), deviceID: "iphone-air")))
        XCTAssertEqual(E2EPairingKeyChange.after(localOnly: false, sentKey: nil, deviceID: "iphone-air"), .remove)
    }

    func testSuccessSuffixNeedsTheSentKeyStored() {
        let record = E2EKeyRecord(key: Data(repeating: 9, count: 32), deviceID: "iphone-air")
        let stored = MemoryE2EKeyStore(["android-A": record])
        XCTAssertEqual(E2EPairingKeyChange.save(record).successSuffix(agentID: "android-A", store: stored), "，云端短信已加密")
        XCTAssertEqual(E2EPairingKeyChange.save(record).successSuffix(agentID: "android-B", store: stored), "")
        let other = E2EKeyRecord(key: Data(repeating: 8, count: 32), deviceID: "iphone-air")
        XCTAssertEqual(E2EPairingKeyChange.save(other).successSuffix(agentID: "android-A", store: stored), "")
        XCTAssertEqual(E2EPairingKeyChange.remove.successSuffix(agentID: "android-A", store: stored), "")
    }

    func testRegistrationNeverEncodesE2EKey() throws {
        // The same registration is later sent unsealed to /api/push/register and the Relay.
        let cloud = AgentPushRegistration(cloudModeEnabled: true, deviceID: "iphone-air", deviceSecret: "device-secret",
            token: "voip", alertToken: "alert", watchVoIPToken: "", watchBundleID: "",
            liveActivityPushToStartToken: "", bundleID: "com.example.airsim", environment: "sandbox",
            relayURL: "https://relay.example", vowlanSecret: "vowlan")
        for registration in [cloud, AgentPushRegistration.local(vowlanSecret: "vowlan")] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(registration)) as? [String: Any])
            XCTAssertNil(object["e2e_key"])
        }
    }
}
