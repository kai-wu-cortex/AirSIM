import CryptoKit
import Foundation
import XCTest
@testable import AirSIM

final class PureLocalModeTests: XCTestCase {
    func testLocalCallModesDoNotClaimRelayIsDisabled() {
        for mode in [AirSIMConnectionMode.vowlan, .bluetooth, .localDual, .cloud, .automatic] {
            let cloud = ConnectionModeRuntimePolicy(mode: mode).startsCloud
            XCTAssertEqual(CloudRelayStatusCopy.text(pureLocal: true, cloudOnline: true, usesCloudCalls: cloud), "纯本地模式已阻断")
            XCTAssertEqual(CloudRelayStatusCopy.text(pureLocal: false, cloudOnline: nil, usesCloudCalls: cloud), "尚未检查，可手动自检")
            XCTAssertTrue(CloudRelayStatusCopy.text(pureLocal: false, cloudOnline: true, usesCloudCalls: cloud).contains("Agent 在线"))
            XCTAssertTrue(CloudRelayStatusCopy.text(pureLocal: false, cloudOnline: false, usesCloudCalls: cloud).contains("Agent 无有效心跳"))
        }
    }
    func testWireIdentifiersRejectTrailingLineBreaks() {
        for suffix in ["\n", "\r", "\r\n"] {
            XCTAssertFalse(PureLocalCommand.validID("fixture-agent" + suffix))
            XCTAssertFalse(PureLocalCommand.validOperation("00000000-0000-4000-8000-000000000001" + suffix))
        }
    }
    private let operation = "00000000-0000-4000-8000-000000000001"
    private var key: Curve25519.Signing.PrivateKey { try! .init(rawRepresentation: Data(repeating: 1, count: 32)) }

    func testSignatureMatchesAndroidAndGoFixtureAndRejectsModifiedCommand() throws {
        let command = try PureLocalCommand.signed(agentID: "fixture-agent", operationID: operation, enabled: true, revision: 0, key: key)
        XCTAssertEqual(command.ownerPublicKey, "iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=")
        // Verify the shared vector rather than require identical signing output:
        // platform implementations may randomize signing without changing verification.
        var fixture = command
        fixture.signature = "fOw9C+rw4HzGV4znLFF7TDD7l28ZnHuCNArerVlWy12I2KZq3M2qz/74FPQej314vFBa0rMLorhT7shVJPc6Dw=="
        XCTAssertNoThrow(try fixture.verify(agentID: "fixture-agent"))
        XCTAssertNoThrow(try command.verify(agentID: "fixture-agent"))
        var altered = command; altered.enabled = false
        XCTAssertThrowsError(try altered.verify(agentID: "fixture-agent"))
        XCTAssertThrowsError(try command.verify(agentID: "other"))
        XCTAssertThrowsError(try PureLocalCommand.signed(agentID: "peer\ninjected", operationID: operation, enabled: true, revision: 0, key: key))
    }

    func testEnteringCapturesPreferencesOnceAndRestartDoesNotClaimConfirmed() throws {
        let first = enter()
        let repeated = PureLocalModePolicy.reduce(state: first, event: .enter(mode: "localDual", cloud: false, callActive: false))
        XCTAssertEqual(repeated.snapshot?.priorMode, "automatic")
        XCTAssertEqual(repeated.snapshot?.priorCloud, true)
        XCTAssertTrue(repeated.blocksRelay)
        XCTAssertFalse(repeated.isConfirmed)
        let data = try JSONEncoder().encode(repeated.snapshot)
        let restored = PureLocalModePolicy.restore(data)
        XCTAssertEqual(restored.snapshot, first.snapshot)
        XCTAssertTrue(restored.blocksRelay)
        XCTAssertFalse(restored.isConfirmed)
        XCTAssertTrue(PureLocalModePolicy.restore(Data("broken".utf8)).blocksRelay)
        XCTAssertFalse(PureLocalModePolicy.restore(nil).blocksRelay)
    }

    func testActiveCallPreventsEnterAndExit() {
        XCTAssertFalse(PureLocalModePolicy.reduce(state: .init(), event: .enter(mode: "cloud", cloud: true, callActive: true)).blocksRelay)
        let active = enter()
        XCTAssertEqual(PureLocalModePolicy.reduce(state: active, event: .exit(callActive: true)).snapshot?.intent, .enabled)
    }

    func testACKNeedsMatchingOperationOwnerPeerAndDrainIncludingAVF() throws {
        let (state, command) = try pending()
        var status = ack(command)
        for altered in [status.with(agent: "other"), status.with(operation: "00000000-0000-4000-8000-000000000002"), status.with(owner: "wrong")] {
            XCTAssertFalse(PureLocalModePolicy.reduce(state: state, event: .ack(altered)).isConfirmed)
        }
        status.drained = false
        XCTAssertFalse(PureLocalModePolicy.reduce(state: state, event: .ack(status)).isConfirmed)
        status.drained = true; status.avfRequired = true; status.avfConfirmed = false
        XCTAssertFalse(PureLocalModePolicy.reduce(state: state, event: .ack(status)).isConfirmed)
        status.avfConfirmed = true
        let confirmed = PureLocalModePolicy.reduce(state: state, event: .ack(status))
        XCTAssertTrue(confirmed.isConfirmed)
        XCTAssertFalse(PureLocalModePolicy.reduce(state: confirmed, event: .disconnected).isConfirmed)
    }

    func testBindingChangeRetainsOldDeviceTransactionButInvalidatesConfirmation() throws {
        let (state, command) = try pending()
        let confirmed = PureLocalModePolicy.reduce(state: state, event: .ack(ack(command)))
        let changed = PureLocalModePolicy.reduce(state: confirmed, event: .bind("other"))
        XCTAssertFalse(changed.isConfirmed)
        XCTAssertEqual(changed.snapshot?.peers["fixture-agent"]?.command, command)
        XCTAssertNil(changed.snapshot?.peers["other"])
        XCTAssertFalse(PureLocalModePolicy.reduce(state: changed, event: .ack(ack(command))).isConfirmed)
    }

    func testAndroidLocalExitStopsRetriesUntilExplicitResync() throws {
        let (state, command) = try pending()
        var status = ack(command); status.enabled = false; status.revision = 2; status.source = "android_local"
        let override = PureLocalModePolicy.reduce(state: state, event: .ack(status))
        XCTAssertTrue(override.blocksRelay)
        XCTAssertTrue(override.peerExited)
        XCTAssertFalse(override.maySynchronize)
        XCTAssertFalse(PureLocalModePolicy.reduce(state: override, event: .ack(ack(command))).isConfirmed)
        XCTAssertTrue(PureLocalModePolicy.reduce(state: override, event: .resynchronize).maySynchronize)
    }

    func testExitStaysBlockedUntilRemoteRestoreACKAndRetainsHistoricalDeviceRecord() throws {
        let (pendingState, command) = try pending()
        var state = PureLocalModePolicy.reduce(state: pendingState, event: .ack(ack(command)))
        state = PureLocalModePolicy.reduce(state: state, event: .exit(callActive: false))
        XCTAssertTrue(state.blocksRelay)
        let exit = try PureLocalCommand.signed(agentID: "fixture-agent", operationID: "00000000-0000-4000-8000-000000000002", enabled: false, revision: 1, key: key)
        state = PureLocalModePolicy.reduce(state: state, event: .operation(exit))
        XCTAssertTrue(PureLocalModePolicy.reduce(state: state, event: .ack(ack(command))).blocksRelay)
        state = PureLocalModePolicy.reduce(state: state, event: .ack(ack(exit)))
        XCTAssertTrue(state.readyToRestore)
        XCTAssertTrue(state.blocksRelay, "ACK cannot release before preferences and persistent policy restore")
    }

    func testACKProofAuthenticatesFullStatusAndNonce() throws {
        let (_, command) = try pending()
        let status = ack(command), secret = Data(repeating: 7, count: 32)
        let proof = try status.proof(nonce: "fixture-nonce", secret: secret)
        XCTAssertTrue(status.verifyProof(proof, nonce: "fixture-nonce", secret: secret))
        XCTAssertFalse(status.verifyProof(proof, nonce: "different", secret: secret))
        var changed = status; changed.avfRequired = true
        XCTAssertFalse(changed.verifyProof(proof, nonce: "fixture-nonce", secret: secret))
    }

    func testKeyStorageFailureOrMissingExistingIdentityNeverCreatesReplacement() throws {
        var creates = 0
        let missing = PureLocalOwnerKeyStore(load: { nil }, save: { _ in creates += 1 })
        XCTAssertThrowsError(try missing.key(allowCreate: false))
        XCTAssertEqual(creates, 0)
        _ = try missing.key(allowCreate: true)
        XCTAssertEqual(creates, 1)
        let locked = PureLocalOwnerKeyStore(load: { throw PureLocalProtocolError.keyUnavailable }, save: { _ in creates += 1 })
        XCTAssertThrowsError(try locked.key(allowCreate: true))
        XCTAssertEqual(creates, 1)
    }

    private func enter() -> PureLocalModePolicy.State { PureLocalModePolicy.reduce(state: .init(), event: .enter(mode: "automatic", cloud: true, callActive: false)) }
    private func pending() throws -> (PureLocalModePolicy.State, PureLocalCommand) {
        var state = PureLocalModePolicy.reduce(state: enter(), event: .bind("fixture-agent"))
        state = PureLocalModePolicy.reduce(state: state, event: .drained)
        let command = try PureLocalCommand.signed(agentID: "fixture-agent", operationID: operation, enabled: true, revision: 0, key: key)
        return (PureLocalModePolicy.reduce(state: state, event: .operation(command)), command)
    }
    private func ack(_ command: PureLocalCommand) -> PureLocalStatus {
        PureLocalStatus(version: 1, agentID: command.agentID, enabled: command.enabled, revision: command.expectedRevision + 1,
                        lastOperationID: command.operationID, ownerFingerprint: command.ownerFingerprint, source: "remote", drained: true, avfRequired: false, avfConfirmed: false)
    }
}

private extension PureLocalStatus {
    func with(agent: String? = nil, operation: String? = nil, owner: String? = nil) -> Self {
        var copy = self
        if let agent { copy.agentID = agent }; if let operation { copy.lastOperationID = operation }; if let owner { copy.ownerFingerprint = owner }
        return copy
    }
}
