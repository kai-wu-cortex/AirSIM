import Combine
import CoreBluetooth
import CryptoKit
import Foundation
import Security
import UIKit

enum VoBLEConnectionState: Equatable, Sendable {
    case stopped, bluetoothUnavailable, scanning, connecting, connected, authenticating, ready
    case failed(String)
}

struct VoBLEReconnectBarrier {
    private(set) var disconnectingID: UUID?
    var permitsConnection: Bool { disconnectingID == nil }
    mutating func begin(_ id: UUID) { disconnectingID = id }
    mutating func finish(_ id: UUID) -> Bool {
        guard disconnectingID == id else { return false }
        disconnectingID = nil
        return true
    }

    mutating func finishIfDisconnected(_ id: UUID, state: CBPeripheralState) -> Bool {
        guard state == .disconnected else { return false }
        return finish(id)
    }
}

enum VoBLEConnectionTimeoutPolicy {
    static let timeout: TimeInterval = 8

    static func shouldExpire(state: VoBLEConnectionState, enabled: Bool,
                             elapsed: TimeInterval, isBackground: Bool = false,
                             systemReconnecting: Bool = false) -> Bool {
        enabled && state == .connecting && !isBackground && !systemReconnecting && elapsed >= timeout
    }
}

enum VoBLEConnectionEvent: Equatable, Sendable {
    case bluetoothPoweredOn, bluetoothUnavailable, connected, characteristicsReady, stopped, servicesInvalidated
    case discovered(UUID), restored(UUID), controlSubscription(Bool)
    case authenticated(identity: String), authenticationFailed(String)
    case disconnected(String?)
}

struct VoBLEConnectionReducer: Sendable {
    private(set) var state: VoBLEConnectionState = .stopped
    private(set) var peripheralID: UUID?
    private(set) var authenticatedIdentity: String?
    private var characteristicsReady = false
    private var controlSubscribed = false

    mutating func apply(_ event: VoBLEConnectionEvent) {
        switch event {
        case .bluetoothPoweredOn:
            // CBCentralManager may repeat poweredOn as the app returns to the
            // foreground. Do not demote a live authenticated connection.
            switch state {
            case .stopped, .bluetoothUnavailable, .failed:
                state = .scanning
            default:
                break
            }
        case .bluetoothUnavailable: reset(); state = .bluetoothUnavailable
        case let .discovered(id): peripheralID = id; state = .connecting
        case .connected: state = .connected
        case .servicesInvalidated: reset(); state = .connected
        case let .restored(id): reset(); peripheralID = id; state = .connecting
        case .characteristicsReady:
            characteristicsReady = true; state = authenticatedIdentity == nil ? .authenticating : state
            publishReady()
        case let .controlSubscription(value): controlSubscribed = value; publishReady()
        case let .authenticated(identity): authenticatedIdentity = identity; state = .authenticating; publishReady()
        case let .authenticationFailed(message): authenticatedIdentity = nil; state = .failed(message)
        case let .disconnected(message): reset(); state = message.map(Self.failed) ?? .scanning
        case .stopped: reset(); peripheralID = nil; state = .stopped
        }
    }

    private mutating func publishReady() {
        if characteristicsReady, controlSubscribed, authenticatedIdentity != nil { state = .ready }
    }
    private mutating func reset() {
        characteristicsReady = false; controlSubscribed = false; authenticatedIdentity = nil
    }
    private static func failed(_ message: String) -> VoBLEConnectionState { .failed(message) }
}

enum VoBLECharacteristicCallbackPolicy {
    static func accepts(_ value: CBCharacteristic, current: [CBCharacteristic?]) -> Bool {
        current.contains { $0 === value }
    }
}

struct VoBLEDiscoveredPeer: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let signal: Int
}

struct VoBLEControlResponse: Equatable, Sendable {
    let requestID: String
    let generation: UInt64
    let success: Bool
    let code: String
    let detail: String
}

struct VoBLEAndroidEvent: Equatable, Sendable {
    let callID: String
    let generation: UInt64
    let direction: String
    let state: String
    let number: String
}

enum VoBLECentralError: LocalizedError, Equatable {
    case notReady, invalidResponse, authenticationFailed, commandTimedOut, disconnected
    case bluetooth(String)
    var errorDescription: String? {
        switch self {
        case .notReady: "蓝牙 Agent 尚未完成认证"
        case .invalidResponse: "蓝牙 Agent 响应无效"
        case .authenticationFailed: "蓝牙消息认证失败"
        case .commandTimedOut: "蓝牙命令响应超时"
        case .disconnected: "蓝牙连接已断开"
        case let .bluetooth(message): message
        }
    }
}

enum VoBLEPairingRecovery {
    static func userMessage(for message: String) -> String {
        let normalized = message.lowercased()
        if normalized.contains("already paired") {
            return "Android 仍保存旧的 VoBLE 凭据。请在 Android AirSIM → 设置 → VoBLE 认证中清除旧配对，再重新配对。"
        }
        if normalized.contains("reconnect authentication failed") {
            return "两端 VoBLE 密钥不一致。请在 Android AirSIM → 设置 → VoBLE 认证中清除旧配对，再重新配对。"
        }
        if normalized.contains("peer is not paired") {
            return "Android 已没有对应的 VoBLE 凭据。请清除本机旧凭据，然后重新核对安全码。"
        }
        return message
    }
}

/// Owns expensive pairing crypto and blocking Keychain I/O, never CB objects.
actor VoBLEPairingWorker {
    struct Prepared: Sendable {
        let publicKey: Data
        let nonce: Data
        let transcript: VoBLEPairingTranscript
        let material: VoBLEPairingMaterial
        let reconnectTag: Data?
    }
    private let store: any VoBLEPairingStoring
    init(store: any VoBLEPairingStoring) { self.store = store }

    func prepare(identity: String, androidPublic: Data, androidNonce: Data) throws -> Prepared {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        var nonce = Data(count: 32)
        let status = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw VoBLECentralError.authenticationFailed }
        let publicKey = privateKey.publicKey.rawRepresentation
        let transcript = VoBLEPairingTranscript(androidIdentity: identity,
            androidPublicKey: androidPublic, iphonePublicKey: publicKey,
            androidNonce: androidNonce, iphoneNonce: nonce)
        let material = try VoBLESessionAuthenticator.derivePairing(
            privateKey: privateKey.rawRepresentation, peerPublicKey: androidPublic, transcript: transcript)
        let stored = try store.load(identity: identity)
        let tag = try stored.map {
            try VoBLESessionAuthenticator.reconnectTag(pairingKey: $0.pairingKey, transcript: transcript)
        }
        return Prepared(publicKey: publicKey, nonce: nonce, transcript: transcript,
                        material: material, reconnectTag: tag)
    }

    func save(_ peer: VoBLEStoredPeer) throws { try store.save(peer) }
    func revoke(identity: String) throws { try store.revoke(identity: identity) }
}

@MainActor
final class VoBLECentralController: NSObject, ObservableObject, VoBLECentralControlling, VoBLEMediaWriting {
    static let serviceUUID = CBUUID(string: "7e57a000-7a17-4d9f-9a3c-41a17b1e0001")
    static let capabilityUUID = CBUUID(string: "7e57a001-7a17-4d9f-9a3c-41a17b1e0001")
    static let pairingUUID = CBUUID(string: "7e57a002-7a17-4d9f-9a3c-41a17b1e0001")
    static let controlRXUUID = CBUUID(string: "7e57a003-7a17-4d9f-9a3c-41a17b1e0001")
    static let controlTXUUID = CBUUID(string: "7e57a004-7a17-4d9f-9a3c-41a17b1e0001")
    static let audioUplinkUUID = CBUUID(string: "7e57a005-7a17-4d9f-9a3c-41a17b1e0001")
    static let audioDownlinkUUID = CBUUID(string: "7e57a006-7a17-4d9f-9a3c-41a17b1e0001")
    static let diagnosticsUUID = CBUUID(string: "7e57a007-7a17-4d9f-9a3c-41a17b1e0001")

    @Published private(set) var state: VoBLEConnectionState = .stopped
    @Published private(set) var discoveredPeers: [VoBLEDiscoveredPeer] = []
    @Published private(set) var pendingSAS: String?
    @Published private(set) var authenticatedIdentity: String?
    @Published private(set) var recoverableIdentity: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var deviceInformation: AndroidAgentMetadata?
    var currentDeviceName: String? { peripheral?.name }
    var onEvent: ((VoBLEAndroidEvent) -> Void)?
    var onAudioDownlinkFragment: ((Data) -> Void)?
    var onReadyToSendAudio: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onReady: (() -> Void)?

    private struct PairingAttempt {
        let challengeID: String, androidIdentity: String
        let iphonePublic: Data, iphoneNonce: Data
        let transcript: VoBLEPairingTranscript
        let material: VoBLEPairingMaterial
    }
    private struct WriteBatch { let characteristic: CBCharacteristic; let fragments: [Data]; var index: Int }
    private struct PendingCommand {
        let generation: UInt64
        let continuation: CheckedContinuation<VoBLEControlResponse, Error>
        let timeout: Task<Void, Never>
    }

    private var reducer = VoBLEConnectionReducer()
    private var central: CBCentralManager?
    private var enabled = false
    private var reconnectBarrier = VoBLEReconnectBarrier()
    private var queuedPeer: (CBPeripheral, Bool)?
    private var peripheral: CBPeripheral?
    private var capability: CBCharacteristic?
    private var pairing: CBCharacteristic?
    private var controlRX: CBCharacteristic?
    private var controlTX: CBCharacteristic?
    private(set) var audioUplink: CBCharacteristic?
    private(set) var audioDownlink: CBCharacteristic?
    private var diagnostics: CBCharacteristic?
    private var discoveryRetries = 0
    private var currentService: CBService?
    private var discoveredRequiredCharacteristics = false
    private var pairingSubscribed = false
    private var pairingStarted = false
    private var pairingAttempt: PairingAttempt?
    private var pairingReassembler = VoBLEMessageReassembler()
    private var controlReassembler = VoBLEMessageReassembler()
    private var replayWindow = VoBLEReplayWindow()
    private var writeBatches: [WriteBatch] = []
    private var messageID: UInt16 = 0
    private var sessionID = Data()
    private var activePeer: VoBLEStoredPeer?
    private var pendingCommands: [String: PendingCommand] = [:]
    private var connectionTimeoutTask: Task<Void, Never>?
    private var cancellationObservationTask: Task<Void, Never>?
    private let pairingWorker: VoBLEPairingWorker
    private var pairingTask: Task<Void, Never>?
    private var queuedPairingMessages = 0
    private var connectionRevision: UInt64 = 0
    private let peripheralPreferenceKey = "airsim.voble.peripheral-id"
    private var explicitPairingPeripheral: UUID?
    private var deviceInformationRevision: UInt64 = 0
    private var applicationIsBackground = UIApplication.shared.applicationState == .background
    private var systemReconnecting = false

    init(pairingStore: any VoBLEPairingStoring = VoBLEPairingStore()) {
        self.pairingWorker = VoBLEPairingWorker(store: pairingStore)
        super.init()
    }

    func start() {
#if DEBUG
        print("[AirSIM VoBLE Connection] start enabled=\(enabled) waitingDisconnect=\(!reconnectBarrier.permitsConnection)")
#endif
        guard !enabled else { return }
        enabled = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.eric3u.airsim.voble.central",
                CBCentralManagerOptionShowPowerAlertKey: true,
            ])
        } else if central?.state == .poweredOn { restoreOrScan() }
    }

    // Recreate the restoration manager on a background launch without showing
    // first-use permission prompts. Fresh authentication is still mandatory.
    func restoreInBackgroundIfAuthorized() {
        guard UIApplication.shared.applicationState == .background,
              CBManager.authorization == .allowedAlways else { return }
        setApplicationIsBackground(true)
        start()
    }

    func setApplicationIsBackground(_ value: Bool) {
        applicationIsBackground = value
        connectionTimeoutTask?.cancel(); connectionTimeoutTask = nil
        if !value, !systemReconnecting, state == .connecting, let peripheral {
            scheduleConnectionTimeout(for: peripheral)
        }
    }

    func stop() {
#if DEBUG
        print("[AirSIM VoBLE Connection] stop")
#endif
        enabled = false; explicitPairingPeripheral = nil; central?.stopScan()
        queuedPeer = nil
        cancelCurrentConnection()
        failPending(with: VoBLECentralError.disconnected)
        onDisconnected?()
        resetConnection(); apply(.stopped)
    }

    func connect(_ peer: VoBLEDiscoveredPeer) {
        guard enabled, let central,
              let selected = central.retrievePeripherals(withIdentifiers: [peer.id]).first else { return }
        explicitPairingPeripheral = peer.id
        connect(selected, restored: false)
    }

    func refreshDeviceInformation() async {
        guard state == .ready, let identity = authenticatedIdentity else { return }
        let session = sessionID
        deviceInformationRevision &+= 1
        let revision = deviceInformationRevision
        deviceInformation = nil
        do {
            let response = try await send(command: "device_info")
            guard response.success, state == .ready, authenticatedIdentity == identity, sessionID == session,
                  deviceInformationRevision == revision else { return }
            deviceInformation = try AndroidAgentMetadata.decode(Data(response.detail.utf8), expectedID: identity)
        } catch {
            // Older Android APKs may not support metadata. Never substitute a cached SIM number.
            if sessionID == session, deviceInformationRevision == revision { deviceInformation = nil }
        }
    }

    func forgetDevice(_ identity: String) async throws {
        if authenticatedIdentity == identity || recoverableIdentity == identity {
            if let peripheral {
                PairedAndroidDeviceStore.rememberPeripheral(peripheral.identifier.uuidString, for: identity)
            }
            if state == .ready, authenticatedIdentity == identity {
                // Best effort remote revocation; local deletion also works when the Android is offline.
                _ = try? await send(command: "unpair")
            }
            let resumeScanning = enabled
            stop()
            let revision = connectionRevision
            try await pairingWorker.revoke(identity: identity)
            guard connectionRevision == revision else { return }
            UserDefaults.standard.removeObject(forKey: peripheralPreferenceKey)
            recoverableIdentity = nil
            if resumeScanning { start() }
        } else {
            try await pairingWorker.revoke(identity: identity)
        }
    }

    func confirmPairing() {
        guard let attempt = pairingAttempt, pendingSAS == attempt.material.sas else { return }
        sendPairingConfirmation(attempt: attempt, reconnectTag: nil)
    }

    func cancelPairing() {
        pairingAttempt = nil; pendingSAS = nil
        VoBLEPairingConnectionReset.perform(on: self, resumeScanning: enabled)
    }

    func revokeCurrentPeer() {
        guard let identity = activePeer?.identity ?? pairingAttempt?.androidIdentity else { return }
        clearCredentialAndRetry(identity: identity)
    }

    func clearLocalCredentialAndRetry() {
        guard let identity = activePeer?.identity
                ?? pairingAttempt?.androidIdentity
                ?? recoverableIdentity else { return }
        clearCredentialAndRetry(identity: identity)
    }

    private func clearCredentialAndRetry(identity: String) {
        let resumeScanning = enabled
        stop()
        recoverableIdentity = nil
        UserDefaults.standard.removeObject(forKey: peripheralPreferenceKey)
        let revision = connectionRevision
        Task { [weak self] in
            guard let self else { return }
            do {
                // Serial with any in-flight save; deletion must win over it.
                try await self.pairingWorker.revoke(identity: identity)
                guard self.connectionRevision == revision else { return }
                if resumeScanning { self.start() }
            } catch {
                if self.connectionRevision == revision { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func unpairCurrentPeer() async throws {
        do {
            guard let identity = activePeer?.identity else { throw VoBLECentralError.notReady }
            let response = try await send(command: "unpair")
            guard response.success else {
                throw VoBLECentralError.bluetooth(response.detail.isEmpty ? response.code : response.detail)
            }
            let resumeScanning = enabled
            stop()
            let revision = connectionRevision
            try await pairingWorker.revoke(identity: identity)
            guard connectionRevision == revision else { return }
            UserDefaults.standard.removeObject(forKey: peripheralPreferenceKey)
            activePeer = nil
            authenticatedIdentity = nil
            recoverableIdentity = nil
            if resumeScanning { start() }
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func send(command: String, callID: String = "", generation: UInt64 = 0, number: String = "") async throws -> VoBLEControlResponse {
        guard state == .ready, let peer = activePeer, !sessionID.isEmpty,
              let controlRX else { throw VoBLECentralError.notReady }
        let requestID = UUID().uuidString
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let nonce = try randomData(count: 12)
        let body = try JSONSerialization.data(withJSONObject: [
            "request_id": requestID, "timestamp_ms": timestamp, "number": number,
        ])
        let keys = try VoBLESessionAuthenticator.deriveSessionKeys(
            pairingKey: peer.pairingKey, sessionID: sessionID, callID: callID, generation: generation)
        let unsigned = VoBLEControlEnvelope(
            command: command, callID: callID, generation: generation,
            sessionID: sessionID, nonce: nonce, ciphertext: body,
            authenticationTag: Data(repeating: 0, count: 16))
        let prefix = try unsigned.encoded().dropLast(16)
        let tag = try VoBLESessionAuthenticator.tag(
            message: authenticationMessage(nonce: nonce, timestampMillis: timestamp, payload: Data(prefix)),
            key: keys.control)
        let encoded = try VoBLEControlEnvelope(
            command: command, callID: callID, generation: generation,
            sessionID: sessionID, nonce: nonce, ciphertext: body, authenticationTag: tag).encoded()

        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.timeoutCommand(requestID)
            }
            pendingCommands[requestID] = PendingCommand(
                generation: generation, continuation: continuation, timeout: timeout)
            do { try enqueueMessage(encoded, type: .control, characteristic: controlRX) }
            catch {
                pendingCommands.removeValue(forKey: requestID)?.timeout.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    func mediaKey(callID: String, generation: UInt64) throws -> Data {
        guard state == .ready, let peer = activePeer, !sessionID.isEmpty else {
            throw VoBLECentralError.notReady
        }
        return try VoBLESessionAuthenticator.deriveSessionKeys(
            pairingKey: peer.pairingKey, sessionID: sessionID,
            callID: callID, generation: generation).media
    }

    var canSendWriteWithoutResponse: Bool {
        peripheral?.canSendWriteWithoutResponse == true && audioUplink != nil
    }

    var maximumWriteLength: Int {
        peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 20
    }

    func writeWithoutResponse(_ data: Data) {
        guard let peripheral, let audioUplink else { return }
        peripheral.writeValue(data, for: audioUplink, type: .withoutResponse)
    }

    private func restoreOrScan() {
        guard enabled, reconnectBarrier.permitsConnection,
              let central, central.state == .poweredOn else { return }
        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting || systemReconnecting {
            if peripheral.state == .connected, state == .connecting {
                apply(.connected)
                peripheral.discoverServices([Self.serviceUUID])
            }
            return
        }
        // Scan current advertisements instead of reconnecting from the cached peripheral record.
        discoveredPeers.removeAll(); apply(.bluetoothPoweredOn)
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
        ])
    }

    private func connect(_ value: CBPeripheral, restored: Bool) {
        guard enabled else { return }
        guard reconnectBarrier.permitsConnection else { queuedPeer = (value, restored); return }
        if let current = peripheral {
            if current === value, state == .ready || state == .connecting || state == .authenticating {
                return
            }
            queuedPeer = (value, restored)
            cancelCurrentConnection()
            failPending(with: VoBLECentralError.disconnected)
            onDisconnected?()
            resetConnection()
            apply(.stopped)
            if reconnectBarrier.permitsConnection { continueAfterCancellation() }
            return
        }
        central?.stopScan(); resetConnection(keepingPeripheral: true)
        peripheral = value; value.delegate = self
        apply(restored ? .restored(value.identifier) : .discovered(value.identifier))
        if value.state == .connected {
            apply(.connected)
            value.discoverServices([Self.serviceUUID])
        } else {
            var options: [String: Any] = [:]
            if #available(iOS 17.0, *) { options[CBConnectPeripheralOptionEnableAutoReconnect] = true }
            central?.connect(value, options: options)
            scheduleConnectionTimeout(for: value)
        }
    }

    private func scheduleConnectionTimeout(for value: CBPeripheral) {
        connectionTimeoutTask?.cancel()
        guard !applicationIsBackground, !systemReconnecting else { return }
        let started = ContinuousClock.now
        connectionTimeoutTask = Task { [weak self, weak value] in
            do { try await Task.sleep(for: .seconds(VoBLEConnectionTimeoutPolicy.timeout)) }
            catch { return }
            guard let self, let value, self.peripheral === value else { return }
            let duration = started.duration(to: .now).components
            let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            guard VoBLEConnectionTimeoutPolicy.shouldExpire(state: self.state,
                      enabled: self.enabled, elapsed: elapsed,
                      isBackground: self.applicationIsBackground,
                      systemReconnecting: self.systemReconnecting) else { return }
#if DEBUG
            print("[AirSIM VoBLE Connection] connect_timeout; falling back to scan")
#endif
            // A cached peripheral can remain .connecting indefinitely after
            // Android re-creates its GATT server. Cancel it before scanning for
            // fresh advertisements; do not immediately retry the same cache.
            self.queuedPeer = nil
            self.cancelCurrentConnection()
            self.failPending(with: VoBLECentralError.disconnected)
            self.onDisconnected?()
            self.resetConnection()
            self.apply(.stopped)
            if self.reconnectBarrier.permitsConnection { self.continueAfterCancellation() }
        }
    }

    private func cancelCurrentConnection() {
        guard let peripheral else { return }
        peripheral.delegate = nil
        if peripheral.state != .disconnected {
            reconnectBarrier.begin(peripheral.identifier)
            central?.cancelPeripheralConnection(peripheral)
            observeCancellation(of: peripheral)
        }
    }

    private func observeCancellation(of value: CBPeripheral) {
        cancellationObservationTask?.cancel()
        cancellationObservationTask = Task { [weak self] in
            // Pending connection cancellation can update the peripheral state
            // without delivering a disconnect callback. Observe the actual
            // state, never unlock the barrier just because time has elapsed.
            for attempt in 0..<80 {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard let self, self.reconnectBarrier.disconnectingID == value.identifier else { return }
#if DEBUG
                if attempt == 0 {
                    print("[AirSIM VoBLE Connection] cancellation_observed peripheralState=\(value.state.rawValue)")
                }
#endif
                if self.reconnectBarrier.finishIfDisconnected(value.identifier, state: value.state) {
                    self.continueAfterCancellation()
                    return
                }
            }
            guard let self, self.enabled,
                  self.reconnectBarrier.disconnectingID == value.identifier else { return }
            self.apply(.authenticationFailed("旧蓝牙连接尚未释放，请稍后重试"))
        }
    }

    private func continueAfterCancellation() {
        cancellationObservationTask?.cancel(); cancellationObservationTask = nil
#if DEBUG
        print("[AirSIM VoBLE Connection] cancellation_finished enabled=\(enabled) waitingDisconnect=\(!reconnectBarrier.permitsConnection)")
#endif
        guard enabled, reconnectBarrier.permitsConnection else { return }
        if let (peer, restored) = queuedPeer {
            queuedPeer = nil
            connect(peer, restored: restored)
        } else { restoreOrScan() }
    }

    private func resetConnection(keepingPeripheral: Bool = false) {
        connectionRevision &+= 1
        pairingTask?.cancel(); pairingTask = nil; queuedPairingMessages = 0
        systemReconnecting = false
        connectionTimeoutTask?.cancel(); connectionTimeoutTask = nil
        pairing = nil; controlRX = nil; controlTX = nil; audioUplink = nil; audioDownlink = nil
        diagnostics = nil; capability = nil; pairingSubscribed = false; pairingStarted = false
        pairingAttempt = nil; pendingSAS = nil; authenticatedIdentity = nil; activePeer = nil
        deviceInformation = nil
        sessionID.removeAll(); pairingReassembler = VoBLEMessageReassembler()
        controlReassembler = VoBLEMessageReassembler(); replayWindow = VoBLEReplayWindow()
        writeBatches.removeAll(); if !keepingPeripheral { peripheral = nil }
        discoveryRetries = 0; currentService = nil; discoveredRequiredCharacteristics = false
    }

    private func invalidateServices() {
        failPending(with: VoBLECentralError.disconnected)
        onDisconnected?()
        resetConnection(keepingPeripheral: true)
        apply(.servicesInvalidated)
    }

    private func apply(_ event: VoBLEConnectionEvent) {
        let previous = state
        reducer.apply(event)
        if state != reducer.state { state = reducer.state }
#if DEBUG
        let label: String
        if case .failed = state { label = "failed" } else { label = String(describing: state) }
        print("[AirSIM VoBLE Connection] state=\(label) enabled=\(enabled) waitingDisconnect=\(!reconnectBarrier.permitsConnection)")
#endif
        let message: String?
        if case let .failed(value) = state { message = value } else { message = nil }
        if errorMessage != message { errorMessage = message }
        if state == .ready, previous != .ready { onReady?() }
    }

    private func acceptsCallback(from value: CBPeripheral) -> Bool {
        enabled && reconnectBarrier.permitsConnection && peripheral === value
    }

    private func beginPairingIfPossible() {
        guard discoveredRequiredCharacteristics, pairingSubscribed, !pairingStarted, let pairing else { return }
        pairingStarted = true
        do {
            try enqueueMessage(JSONSerialization.data(withJSONObject: ["op": "begin"]),
                               type: .pairing, characteristic: pairing)
        } catch { failAuthentication(error.localizedDescription) }
    }

    private func enqueuePairingMessage(_ data: Data) {
        guard queuedPairingMessages < 16 else {
            failAuthentication("蓝牙配对消息过多，请重新连接")
            return
        }
        queuedPairingMessages += 1
        let previous = pairingTask
        let revision = connectionRevision
        pairingTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.connectionRevision == revision else { return }
            await self.handlePairingMessage(data, revision: revision)
            if self.connectionRevision == revision { self.queuedPairingMessages -= 1 }
        }
    }

    private func handlePairingMessage(_ data: Data, revision: UInt64) async {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VoBLECentralError.invalidResponse }
            if object["ready"] as? Bool == true {
                guard let attempt = pairingAttempt,
                      let confirmation = decodeBase64(object["confirmation_tag"] as? String),
                      VoBLESessionAuthenticator.authenticate(
                        message: Data("AirSIM/VoBLE/v1/ready\(attempt.challengeID)".utf8),
                        tag: confirmation, key: attempt.material.pairingKey
                      ) else { throw VoBLECentralError.authenticationFailed }
                try await finishPairing(revision: revision)
                return
            }
            if object["ok"] as? Bool == false {
                let raw = object["error"] as? String ?? "蓝牙配对失败"
                throw VoBLECentralError.bluetooth(VoBLEPairingRecovery.userMessage(for: raw))
            }
            if object["op"] as? String == "prepare" {
                guard let attempt = pairingAttempt,
                      let remoteSAS = object["sas"] as? String,
                      remoteSAS == attempt.material.sas else {
                    throw VoBLECentralError.authenticationFailed
                }
                pendingSAS = remoteSAS
                return
            }
            guard object["op"] as? String == "begin",
                  let challengeID = object["challenge_id"] as? String,
                  let identity = object["android_identity"] as? String,
                  let androidPublic = decodeBase64(object["android_public"] as? String),
                  let androidNonce = decodeBase64(object["android_nonce"] as? String),
                  androidPublic.count == 32, androidNonce.count == 32 else { throw VoBLECentralError.invalidResponse }
            if !PairedAndroidDeviceStore.permits(identity), explicitPairingPeripheral != peripheral?.identifier {
                if let peripheral {
                    PairedAndroidDeviceStore.rememberPeripheral(peripheral.identifier.uuidString, for: identity)
                }
                cancelCurrentConnection()
                resetConnection()
                apply(.disconnected(nil))
                return
            }
            let prepared = try await pairingWorker.prepare(
                identity: identity, androidPublic: androidPublic, androidNonce: androidNonce)
            guard !Task.isCancelled, connectionRevision == revision, enabled else { return }
            let attempt = PairingAttempt(
                challengeID: challengeID, androidIdentity: identity, iphonePublic: prepared.publicKey,
                iphoneNonce: prepared.nonce, transcript: prepared.transcript, material: prepared.material)
            pairingAttempt = attempt
            recoverableIdentity = identity
            if let tag = prepared.reconnectTag {
                sendPairingConfirmation(attempt: attempt, reconnectTag: tag)
            } else { try sendPairingPreparation(attempt) }
        } catch {
            if !Task.isCancelled, connectionRevision == revision { failAuthentication(error.localizedDescription) }
        }
    }

    private func sendPairingPreparation(_ attempt: PairingAttempt) throws {
        guard let pairing else { throw VoBLECentralError.disconnected }
        try enqueueMessage(JSONSerialization.data(withJSONObject: [
            "op": "prepare", "challenge_id": attempt.challengeID,
            "iphone_public": encodeBase64(attempt.iphonePublic),
            "iphone_nonce": encodeBase64(attempt.iphoneNonce),
        ]), type: .pairing, characteristic: pairing)
    }

    private func sendPairingConfirmation(attempt: PairingAttempt, reconnectTag: Data?) {
        guard let pairing else { return }
        do {
            var object: [String: Any] = [
                "op": "confirm", "challenge_id": attempt.challengeID,
                "iphone_public": encodeBase64(attempt.iphonePublic),
                "iphone_nonce": encodeBase64(attempt.iphoneNonce),
            ]
            if let reconnectTag { object["reconnect_tag"] = encodeBase64(reconnectTag) }
            else { object["sas"] = attempt.material.sas }
            try enqueueMessage(JSONSerialization.data(withJSONObject: object), type: .pairing, characteristic: pairing)
            pendingSAS = nil
        } catch { failAuthentication(error.localizedDescription) }
    }

    private func finishPairing(revision: UInt64) async throws {
        guard let attempt = pairingAttempt, let peripheral else { throw VoBLECentralError.invalidResponse }
        if !PairedAndroidDeviceStore.permits(attempt.androidIdentity) {
            guard explicitPairingPeripheral == peripheral.identifier else { throw VoBLECentralError.authenticationFailed }
            PairedAndroidDeviceStore.allowPairing(attempt.androidIdentity)
        }
        let peer = VoBLEStoredPeer(identity: attempt.androidIdentity, pairingKey: attempt.material.pairingKey, createdAt: Date())
        try await pairingWorker.save(peer)
        guard !Task.isCancelled, connectionRevision == revision, enabled else { return }
        activePeer = peer; authenticatedIdentity = peer.identity
        recoverableIdentity = peer.identity
        sessionID = try randomData(count: 16); replayWindow = VoBLEReplayWindow()
        UserDefaults.standard.removeObject(forKey: peripheralPreferenceKey)
        PairedAndroidDeviceStore.rememberPeripheral(peripheral.identifier.uuidString, for: peer.identity)
        explicitPairingPeripheral = nil
        pairingAttempt = nil; pendingSAS = nil; apply(.authenticated(identity: peer.identity))
    }

    private func failAuthentication(_ message: String) {
        pairingAttempt = nil; pendingSAS = nil; apply(.authenticationFailed(message))
    }

    private func enqueueMessage(_ data: Data, type: VoBLEMessageType, characteristic: CBCharacteristic) throws {
        guard let peripheral else { throw VoBLECentralError.disconnected }
        messageID &+= 1
        let fragments = try VoBLEMessageFragmenter.encode(
            data, type: type, messageID: messageID,
            maximumPacketLength: max(20, peripheral.maximumWriteValueLength(for: .withResponse)))
        writeBatches.append(WriteBatch(characteristic: characteristic, fragments: fragments, index: 0))
        if writeBatches.count == 1 { writeNext() }
    }

    private func writeNext() {
        guard let peripheral, let batch = writeBatches.first, batch.index < batch.fragments.count else { return }
        peripheral.writeValue(batch.fragments[batch.index], for: batch.characteristic, type: .withResponse)
    }

    private func handleControlMessage(_ data: Data) {
        do {
            let envelope = try VoBLEControlEnvelope.decode(data)
            guard let peer = activePeer,
                  let body = try JSONSerialization.jsonObject(with: envelope.ciphertext) as? [String: Any],
                  let timestampValue = body["timestamp_ms"] as? NSNumber else { throw VoBLECentralError.invalidResponse }
            let timestamp = timestampValue.int64Value
            let keys = try VoBLESessionAuthenticator.deriveSessionKeys(
                pairingKey: peer.pairingKey, sessionID: envelope.sessionID,
                callID: envelope.callID, generation: envelope.generation)
            guard VoBLESessionAuthenticator.authenticate(
                message: authenticationMessage(nonce: envelope.nonce, timestampMillis: timestamp, payload: Data(data.dropLast(16))),
                tag: envelope.authenticationTag, key: keys.control),
                  replayWindow.accept(nonce: envelope.nonce,
                    timestamp: Date(timeIntervalSince1970: Double(timestamp) / 1_000)) else { throw VoBLECentralError.authenticationFailed }
            if envelope.command == "response", let requestID = body["request_id"] as? String {
                guard let pending = pendingCommands[requestID], pending.generation == envelope.generation else { return }
                pendingCommands.removeValue(forKey: requestID); pending.timeout.cancel()
                pending.continuation.resume(returning: VoBLEControlResponse(
                    requestID: requestID, generation: envelope.generation,
                    success: body["ok"] as? Bool ?? false,
                    code: body["code"] as? String ?? "invalid_response",
                    detail: body["detail"] as? String ?? ""))
            } else if envelope.command == "call_state" {
                onEvent?(VoBLEAndroidEvent(
                    callID: envelope.callID, generation: envelope.generation,
                    direction: body["direction"] as? String ?? "", state: body["state"] as? String ?? "",
                    number: body["number"] as? String ?? ""))
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func timeoutCommand(_ id: String) {
        guard let pending = pendingCommands.removeValue(forKey: id) else { return }
        pending.continuation.resume(throwing: VoBLECentralError.commandTimedOut)
    }
    private func failPending(with error: Error) {
        let values = Array(pendingCommands.values); pendingCommands.removeAll()
        for pending in values { pending.timeout.cancel(); pending.continuation.resume(throwing: error) }
    }
    private func authenticationMessage(nonce: Data, timestampMillis: Int64, payload: Data) -> Data {
        var result = Data([UInt8(truncatingIfNeeded: nonce.count >> 8), UInt8(truncatingIfNeeded: nonce.count)])
        result.append(nonce); var timestamp = UInt64(bitPattern: timestampMillis).bigEndian
        withUnsafeBytes(of: &timestamp) { result.append(contentsOf: $0) }; result.append(payload); return result
    }
    private func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw VoBLECentralError.authenticationFailed }; return data
    }
    private func encodeBase64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func decodeBase64(_ input: String?) -> Data? {
        guard var value = input else { return nil }
        value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4); return Data(base64Encoded: value)
    }
}

extension VoBLECentralController: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Restoration can arrive before the manager finishes leaving .unknown.
        if central.state == .unknown || central.state == .resetting { return }
        if central.state != .poweredOn {
            cancellationObservationTask?.cancel(); cancellationObservationTask = nil
            reconnectBarrier = VoBLEReconnectBarrier()
            queuedPeer = nil
            if peripheral != nil { failPending(with: VoBLECentralError.disconnected); onDisconnected?() }
            resetConnection()
        }
        guard enabled else { return }
        central.state == .poweredOn ? restoreOrScan() : apply(.bluetoothUnavailable)
    }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard enabled else { return }
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? [])
            .filter { PairedAndroidDeviceStore.permitsPeripheral($0.identifier.uuidString) }
        if let value = restored.first(where: { $0.state == .connected })
            ?? restored.first(where: { $0.state == .connecting }) {
            // Adopt the OS object, not a separately retrieved/cached instance.
            // It remains unavailable for dialing until fresh GATT authentication.
            resetConnection()
            peripheral = value; value.delegate = self
            apply(.restored(value.identifier))
        }
        restoreOrScan()
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard enabled, reconnectBarrier.permitsConnection else { return }
        let peer = VoBLEDiscoveredPeer(id: peripheral.identifier,
            name: (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "AirSIM Android",
            signal: RSSI.intValue)
        if let index = discoveredPeers.firstIndex(where: { $0.id == peer.id }) {
            if discoveredPeers[index] != peer { discoveredPeers[index] = peer }
        }
        else { discoveredPeers.append(peer) }
        if self.peripheral == nil, PairedAndroidDeviceStore.permitsPeripheral(peer.id.uuidString) {
            connect(peripheral, restored: false)
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard enabled, reconnectBarrier.permitsConnection, self.peripheral === peripheral else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        connectionTimeoutTask?.cancel(); connectionTimeoutTask = nil
        systemReconnecting = false
        apply(.connected); peripheral.discoverServices([Self.serviceUUID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if reconnectBarrier.finish(peripheral.identifier) { continueAfterCancellation(); return }
        guard self.peripheral === peripheral else { return }
        resetConnection()
        apply(.disconnected(error?.localizedDescription ?? "蓝牙连接失败")); if enabled { restoreOrScan() }
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        handleDisconnect(peripheral: peripheral, error: error, isReconnecting: false)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        handleDisconnect(peripheral: peripheral, error: error, isReconnecting: isReconnecting)
    }
    private func handleDisconnect(peripheral: CBPeripheral, error: Error?, isReconnecting: Bool) {
        if reconnectBarrier.finish(peripheral.identifier) { continueAfterCancellation(); return }
        guard self.peripheral === peripheral else { return }
        failPending(with: VoBLECentralError.disconnected)
        // Native automatic reconnect still targets this same peripheral. Keep
        // its reference so didConnect can rediscover and authenticate it.
        resetConnection(keepingPeripheral: isReconnecting)
        onDisconnected?()
        if isReconnecting {
            systemReconnecting = true
            apply(.restored(peripheral.identifier))
        }
        else {
            apply(.disconnected(error?.localizedDescription))
            if enabled { restoreOrScan() }
        }
    }
}

extension VoBLECentralController: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard acceptsCallback(from: peripheral),
              invalidatedServices.contains(where: { $0.uuid == Self.serviceUUID }) else { return }
        invalidateServices()
        peripheral.discoverServices([Self.serviceUUID])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard acceptsCallback(from: peripheral) else { return }
        if let error { apply(.authenticationFailed(error.localizedDescription)); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            apply(.authenticationFailed("未发现 AirSIM 蓝牙服务")); return
        }
        currentService = service
        peripheral.discoverCharacteristics([Self.capabilityUUID, Self.pairingUUID, Self.controlRXUUID,
            Self.controlTXUUID, Self.audioUplinkUUID, Self.audioDownlinkUUID, Self.diagnosticsUUID], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard acceptsCallback(from: peripheral), currentService === service else { return }
        if let error { apply(.authenticationFailed(error.localizedDescription)); return }
        pairing = nil; controlRX = nil; controlTX = nil; audioUplink = nil; audioDownlink = nil
        let required: [(CBUUID, CBCharacteristicProperties, String)] = [
            (Self.pairingUUID, [.write, .indicate], "配对"),
            (Self.controlRXUUID, .write, "控制接收"),
            (Self.controlTXUUID, .indicate, "控制通知"),
            (Self.audioUplinkUUID, .writeWithoutResponse, "音频上行"),
            (Self.audioDownlinkUUID, .notify, "音频下行")
        ]
        let values = service.characteristics ?? []
        let missing = required.compactMap { uuid, properties, name in
            values.contains(where: { $0.uuid == uuid && $0.properties.contains(properties) }) ? nil : name
        }
        guard missing.isEmpty else {
            let attempt = discoveryRetries + 1
            Task { await AgentVerboseTraceRecorder.shared.recordEvent(
                source: "APP", category: "bluetooth", phase: "service_discovery",
                title: "VoBLE 服务发现", fields: ["attempt": String(attempt), "missing": missing.joined(separator: ",")],
                isFailure: true
            ) }
            if discoveryRetries < 2 {
                let retries = discoveryRetries + 1
                invalidateServices()
                discoveryRetries = retries
                // A bounded rediscovery; never weaken required authentication or
                // silently accept an incomplete/old GATT database.
                peripheral.discoverServices([Self.serviceUUID])
            } else {
                apply(.authenticationFailed("AirSIM 蓝牙特征不完整：缺少\(missing.joined(separator: "、"))；请确认安卓 App 版本并重新连接"))
            }
            return
        }
        discoveredRequiredCharacteristics = true
        for value in service.characteristics ?? [] {
            switch value.uuid {
            case Self.capabilityUUID: capability = value; peripheral.readValue(for: value)
            case Self.pairingUUID: pairing = value; peripheral.setNotifyValue(true, for: value)
            case Self.controlRXUUID: controlRX = value
            case Self.controlTXUUID: controlTX = value; peripheral.setNotifyValue(true, for: value)
            case Self.audioUplinkUUID: audioUplink = value
            case Self.audioDownlinkUUID: audioDownlink = value; peripheral.setNotifyValue(true, for: value)
            case Self.diagnosticsUUID: diagnostics = value; peripheral.setNotifyValue(true, for: value)
            default: break
            }
        }
        guard pairing != nil, controlRX != nil, controlTX != nil, audioUplink != nil, audioDownlink != nil else {
            apply(.authenticationFailed("AirSIM 蓝牙特征不完整")); return
        }
        apply(.characteristicsReady)
        beginPairingIfPossible()
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard acceptsCallback(from: peripheral) else { return }
        guard VoBLECharacteristicCallbackPolicy.accepts(characteristic,
            current: [pairing, controlTX, audioDownlink, diagnostics]) else { return }
        if let error { apply(.authenticationFailed(error.localizedDescription)); return }
        if characteristic === pairing { pairingSubscribed = characteristic.isNotifying; beginPairingIfPossible() }
        else if characteristic === controlTX { apply(.controlSubscription(characteristic.isNotifying)) }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard acceptsCallback(from: peripheral) else { return }
        guard error == nil, let value = characteristic.value else { return }
        do {
            if characteristic === pairing, let message = try pairingReassembler.append(value) {
                guard message.type == .pairing else { throw VoBLECentralError.invalidResponse }; enqueuePairingMessage(message.payload)
            } else if characteristic === controlTX, let message = try controlReassembler.append(value) {
                guard message.type == .control else { throw VoBLECentralError.invalidResponse }; handleControlMessage(message.payload)
            } else if characteristic === audioDownlink {
                onAudioDownlinkFragment?(value)
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard acceptsCallback(from: peripheral) else { return }
        guard !writeBatches.isEmpty else { return }
        guard writeBatches.first?.characteristic === characteristic else { return }
        if let error { writeBatches.removeAll(); failAuthentication(error.localizedDescription); return }
        writeBatches[0].index += 1
        if writeBatches[0].index >= writeBatches[0].fragments.count { writeBatches.removeFirst() }
        writeNext()
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard acceptsCallback(from: peripheral) else { return }
        onReadyToSendAudio?()
    }
}
