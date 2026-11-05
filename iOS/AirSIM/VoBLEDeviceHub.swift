import Combine
import Foundation
import CoreBluetooth
import UIKit

@MainActor
final class VoBLEDeviceSession {
    let central: VoBLECentralController
    let media: VoBLEGATTMediaTransport
    let audio: VoBLEAudioEngine
    let calls: VoBLECallCoordinator

    init(central: VoBLECentralController) {
        self.central = central
        media = VoBLEGATTMediaTransport(writer: central)
        audio = VoBLEAudioEngine(transport: media)
        calls = VoBLECallCoordinator(central: central, media: media, audio: audio)
    }
}

enum VoBLEAutoReconnectPolicy {
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponent = min(5, max(0, attempt - 1))
        return min(30, pow(2, Double(exponent)))
    }

    static func shouldReconnect(
        enabled: Bool, known: Bool, selected: Bool,
        state: VoBLEConnectionState
    ) -> Bool {
        guard enabled, known, selected else { return false }
        switch state {
        case .stopped, .failed: return true
        default: return false
        }
    }
}

@MainActor
final class VoBLEDeviceHub: ObservableObject, VoBLECentralControlling {
    let radio: VoBLERadioController
    let placeholder: VoBLEDeviceSession
    @Published private(set) var selectedPeripheralID: UUID?
    private(set) var sessions: [UUID: VoBLEDeviceSession] = [:]
    var onSessionCreated: ((VoBLEDeviceSession) -> Void)?
    var onCallEvent: ((DeviceCallEvent) -> Void)?
    private let pairingStore: any VoBLEPairingStoring
    private let knownPeripheral: (UUID) -> Bool
    private var observations: [UUID: Set<AnyCancellable>] = [:]
    private var radioObservation: AnyCancellable?
    @Published private var enabled = false
    private var handshake: UUID?
    private var pending: [VoBLEDiscoveredPeer] = []
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var reconnectAttempts: [UUID: Int] = [:]
    private var callActive = false

    init(radio: VoBLERadioController? = nil, pairingStore: any VoBLEPairingStoring = VoBLEPairingStore(),
         knownPeripheral: ((UUID) -> Bool)? = nil) {
        self.radio = radio ?? VoBLERadioController()
        self.pairingStore = pairingStore
        self.knownPeripheral = knownPeripheral ?? { id in
            PairedAndroidDeviceStore.records().contains { PairedAndroidDeviceStore.peripheralID(for: $0.id) == id }
        }
        placeholder = VoBLEDeviceSession(central: VoBLECentralController(radio: self.radio, pairingStore: pairingStore))
        radioObservation = self.radio.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        self.radio.onDiscovered = { [weak self] peer in self?.discover(peer) }
        self.radio.onRestored = { [weak self] id in
            guard let self, self.isKnown(id) else { return }
            // The radio forwards the actual OS peripheral immediately after
            // this callback; cached IDs alone never mark a session ready.
            self.prepare(peripheralID: id).central.start()
        }
    }
    var selected: VoBLEDeviceSession { selectedPeripheralID.flatMap { sessions[$0] } ?? placeholder }
    /// Discovery UI only: the placeholder is not an authenticated peer/session.
    var pairingState: VoBLEConnectionState {
        if selectedPeripheralID != nil, selected.central.state != .stopped { return selected.central.state }
        guard enabled else { return .stopped }
        return radio.poweredOn ? .scanning : .bluetoothUnavailable
    }
    func start() {
        if !enabled { enabled = true }
        // A user/mode/foreground transition starts a fresh reconnect budget.
        // Without this, five failed attempts would permanently disable recovery.
        reconnectTasks.values.forEach { $0.cancel() }
        reconnectTasks.removeAll()
        reconnectAttempts.removeAll()
        for value in sessions.values { value.central.start() }
        radio.start()
        if let selectedPeripheralID { attemptReconnect(selectedPeripheralID) }
        syncMediaScanPolicy()
    }

    /// Pause the shared scanner only during a BLE call. An idle authenticated
    /// link must remain discoverable/reconnectable; pausing merely because a
    /// session is ready breaks multi-Agent discovery and existing tests.
    private func syncMediaScanPolicy() {
        if callActive || sessions.values.contains(where: { $0.audio.running }) {
            radio.pauseScanForMedia()
        } else {
            radio.resumeScanAfterMedia()
        }
    }

    func setCallActive(_ active: Bool) {
        guard callActive != active else { return }
        callActive = active
        syncMediaScanPolicy()
    }
    func restoreInBackgroundIfAuthorized() {
        guard UIApplication.shared.applicationState == .background,
              CBManager.authorization == .allowedAlways else { return }
        setApplicationIsBackground(true)
        start()
    }
    func setApplicationIsBackground(_ value: Bool) {
        for session in sessions.values { session.central.setApplicationIsBackground(value) }
    }
    func stop() { stop(except: nil) }
    func stop(except agentID: String?) {
        if enabled { enabled = false }
        pending.removeAll(); handshake = nil
        reconnectTasks.values.forEach { $0.cancel() }
        reconnectTasks.removeAll()
        reconnectAttempts.removeAll()
        for (id, value) in sessions where value.central.authenticatedIdentity != agentID || agentID == nil {
            value.central.stop()
            radio.cancel(peripheralID: id)
        }
        if agentID == nil { radio.stop() }
    }
    func select(peripheralID: UUID) {
        guard sessions[peripheralID] != nil else { return }
        selectedPeripheralID = peripheralID
    }

    /// Called when the user switches Android Agent. Selecting a session is not
    /// enough: a stopped/never-connected session must be started and reconnected.
    func ensureConnected(agentID: String) {
        guard let peripheralID = PairedAndroidDeviceStore.peripheralID(for: agentID) else { return }
        selectedPeripheralID = peripheralID
        start()
        let value = prepare(peripheralID: peripheralID)
        value.central.start()
        if let peer = radio.discoveredPeers.first(where: { $0.id == peripheralID }) {
            value.central.connect(peer)
        } else if let peripheral = radio.peripheral(peripheralID) {
            value.central.connect(VoBLEDiscoveredPeer(
                id: peripheralID,
                name: peripheral.name ?? "AirSIM Android",
                signal: 0
            ))
        } else {
            radio.start()
        }
    }
    func session(for agentID: String) -> VoBLECentralController? { bundle(for: agentID)?.central }
    func bundle(for agentID: String) -> VoBLEDeviceSession? {
        sessions.values.first { $0.central.state == .ready && $0.central.authenticatedIdentity == agentID }
    }
    func retainedBundle(for agentID: String) -> VoBLEDeviceSession? {
        sessions.values.first { $0.central.authenticatedIdentity == agentID || $0.central.recoverableIdentity == agentID }
    }
    func connect(_ peer: VoBLEDiscoveredPeer) {
        start()
        let value = prepare(peripheralID: peer.id)
        selectedPeripheralID = peer.id
        value.central.start()
        value.central.connect(peer)
    }
    func forget(agentID: String) async throws {
        guard let pair = sessions.first(where: {
            $0.value.central.authenticatedIdentity == agentID || $0.value.central.recoverableIdentity == agentID
        }) else {
            try await VoBLEPairingWorker(store: pairingStore).revoke(identity: agentID)
            return
        }
        let (id, value) = pair
        try await value.central.forgetDevice(agentID)
        value.central.stop()
        radio.cancel(peripheralID: id)
        sessions.removeValue(forKey: id)
        observations.removeValue(forKey: id)
        pending.removeAll { $0.id == id }
        reconnectTasks.removeValue(forKey: id)?.cancel()
        reconnectAttempts.removeValue(forKey: id)
        if selectedPeripheralID == id { selectedPeripheralID = nil }
        if handshake == id { handshake = nil; nextHandshake() }
        syncMediaScanPolicy()
        objectWillChange.send()
    }
    @discardableResult
    func prepare(peripheralID: UUID) -> VoBLEDeviceSession {
        if let existing = sessions[peripheralID] { return existing }
        let value = VoBLEDeviceSession(central: VoBLECentralController(radio: radio,
            peripheralID: peripheralID, pairingStore: pairingStore))
        sessions[peripheralID] = value
        value.calls.mediaPermission = { _ in false }
        onSessionCreated?(value)
        value.central.onHandshakeSettled = { [weak self] in
            guard let self, self.handshake == peripheralID else { return }
            self.handshake = nil
            // Do not start another central reentrantly from a disconnect callback.
            // The delayed task only drains the queue; it never clears ownership.
            Task { @MainActor [weak self] in self?.nextHandshake() }
        }
        var subscriptions = Set<AnyCancellable>()
        value.central.$state.dropFirst().receive(on: DispatchQueue.main).sink { [weak self, weak value] state in
            guard let self, let value, value.central.state == state else { return }
            self.objectWillChange.send()
            if state == .ready {
                self.reconnectAttempts[peripheralID] = 0
                self.reconnectTasks.removeValue(forKey: peripheralID)?.cancel()
            }
            if state == .ready, self.selectedPeripheralID == nil { self.selectedPeripheralID = peripheralID }
            if VoBLEAutoReconnectPolicy.shouldReconnect(
                enabled: self.enabled,
                known: self.isKnown(peripheralID),
                selected: self.isReconnectTarget(peripheralID),
                state: state
            ) {
                self.scheduleReconnect(peripheralID)
            }
        }.store(in: &subscriptions)
        value.central.$deviceInformation.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        // The pairing sheet reads pendingSAS/errorMessage directly from the
        // selected central. Those @Published fields are not mirrored by $state,
        // so without this forward the six-digit code appears only after another
        // tap changes selectedPeripheralID and forces a re-render.
        value.central.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        value.audio.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.syncMediaScanPolicy()
        }.store(in: &subscriptions)
        observations[peripheralID] = subscriptions
        return value
    }

    private func isKnown(_ id: UUID) -> Bool {
        knownPeripheral(id)
    }

    private func isReconnectTarget(_ id: UUID) -> Bool {
        if selectedPeripheralID == id { return true }
        return selectedPeripheralID == nil && sessions.count == 1
    }

    private func scheduleReconnect(_ id: UUID) {
        guard enabled, isKnown(id), isReconnectTarget(id) else { return }
        let attempt = (reconnectAttempts[id] ?? 0) + 1
        guard attempt <= 5 else { return }
        reconnectAttempts[id] = attempt
        reconnectTasks[id]?.cancel()
        let delay = VoBLEAutoReconnectPolicy.delay(forAttempt: attempt)
        reconnectTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.attemptReconnect(id)
        }
    }

    private func attemptReconnect(_ id: UUID) {
        guard enabled, isKnown(id), isReconnectTarget(id) else { return }
        let value = prepare(peripheralID: id)
        value.central.start()
        radio.start()
        if let peer = radio.discoveredPeers.first(where: { $0.id == id }) {
            value.central.connect(peer)
        } else if let peripheral = radio.peripheral(id) {
            value.central.connect(VoBLEDiscoveredPeer(
                id: id,
                name: peripheral.name ?? "AirSIM Android",
                signal: 0
            ))
        }
        // A powered-off radio or an RPA change may leave us scanning. Retry with
        // capped backoff; a ready state cancels this task from the state sink.
        reconnectTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self,
                  self.enabled, self.isKnown(id), self.isReconnectTarget(id) else { return }
            if self.sessions[id]?.central.state != .ready {
                self.scheduleReconnect(id)
            }
        }
    }
    private func discover(_ peer: VoBLEDiscoveredPeer) {
        guard enabled, isKnown(peer.id), !pending.contains(where: { $0.id == peer.id }),
              sessions[peer.id]?.central.state != .ready, handshake != peer.id else { return }
        pending.append(peer)
        nextHandshake()
    }
    private func nextHandshake() {
        guard enabled, handshake == nil, !pending.isEmpty else { return }
        let peer = pending.removeFirst()
        handshake = peer.id
        let value = prepare(peripheralID: peer.id)
        value.central.start()
        value.central.connect(peer)
    }
}
