import Combine
import CoreBluetooth
import Foundation

/// The OS boundary is injectable; connection/authentication state remains in
/// the real per-peripheral controller, not in a mock central manager.
@MainActor
protocol VoBLERadioIO: AnyObject {
    var manager: CBCentralManager? { get }
    var poweredOn: Bool { get }
    func start(delegate: any CBCentralManagerDelegate)
    func scan()
    func stopScan()
    func connect(_ id: UUID)
    func cancel(_ id: UUID)
    func peripheral(_ id: UUID) -> CBPeripheral?
}

@MainActor
final class VoBLESystemRadioIO: VoBLERadioIO {
    private(set) var manager: CBCentralManager?
    var poweredOn: Bool { manager?.state == .poweredOn }
    func start(delegate: any CBCentralManagerDelegate) {
        guard manager == nil else { return }
        manager = CBCentralManager(delegate: delegate, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.eric3u.airsim.voble.central",
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }
    func scan() {
        manager?.scanForPeripherals(withServices: [VoBLECentralController.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    func stopScan() { manager?.stopScan() }
    func peripheral(_ id: UUID) -> CBPeripheral? {
        manager?.retrievePeripherals(withIdentifiers: [id]).first
    }
    func connect(_ id: UUID) {
        guard let value = peripheral(id) else { return }
        var options: [String: Any] = [:]
        if #available(iOS 17.0, *) { options[CBConnectPeripheralOptionEnableAutoReconnect] = true }
        manager?.connect(value, options: options)
    }
    func cancel(_ id: UUID) {
        guard let value = peripheral(id) else { return }
        manager?.cancelPeripheralConnection(value)
    }
}

/// One manager and one scan for the whole app. Cancellation is always scoped
/// to an OS peripheral; a session never owns or stops the shared scanner.
@MainActor
final class VoBLERadioController: NSObject, ObservableObject {
    @Published private(set) var discoveredPeers: [VoBLEDiscoveredPeer] = []
    var onDiscovered: ((VoBLEDiscoveredPeer) -> Void)?
    var onRestored: ((UUID) -> Void)?
    var onPoweredOn: (() -> Void)?
    private let io: any VoBLERadioIO
    private final class WeakSession {
        weak var value: VoBLECentralController?
        init(_ value: VoBLECentralController) { self.value = value }
    }
    private var sessions: [UUID: WeakSession] = [:]
    private var enabled = false
    private var recoveryScan: Task<Void, Never>?
    private var lastRecoveryScan = Date.distantPast
    private var lastScanRestart = Date.distantPast
    private var mediaPaused = false
    @Published private(set) var scanning = false
    var poweredOn: Bool { io.poweredOn }
    var manager: CBCentralManager? { io.manager }

    init(io: (any VoBLERadioIO)? = nil) { self.io = io ?? VoBLESystemRadioIO(); super.init() }

    func attach(_ session: VoBLECentralController, peripheralID: UUID) {
        sessions[peripheralID] = WeakSession(session)
    }
    func start() {
        enabled = true
        io.start(delegate: self)
        // iOS may stop a scan without a state callback while the app is
        // suspended. Re-arm once per foreground transition instead of trusting
        // the in-memory flag; otherwise the UI can sit at "discovering" forever.
        if Date().timeIntervalSince(lastScanRestart) >= 10 { rearmScan() }
        scanIfNeeded()
    }

    /// Re-issue the shared scan even when the in-memory scanning flag still
    /// reads true. The timestamp bound keeps repeated session starts in one
    /// render pass from churning the OS scanner.
    func rearmScan() {
        guard enabled, poweredOn, !mediaPaused else { return }
        if scanning { io.stopScan() }
        scanning = false
        lastScanRestart = Date()
        trace("scan_rearmed", fields: ["powered": "true"])
        scanIfNeeded()
    }
    func scanIfNeeded() {
        guard enabled, poweredOn, !scanning, !mediaPaused else { return }
        scanning = true
        io.scan()
        trace("scan_started", fields: ["powered": "true"])
    }

    /// Scanning competes with the BLE connection for radio time. The old
    /// single-device controller stopped scanning on connect; the shared radio
    /// must do the same while a call is actually carrying audio.
    func pauseScanForMedia() {
        guard !mediaPaused else { return }
        mediaPaused = true
        if scanning { io.stopScan() }
        scanning = false
        trace("scan_paused_media")
    }

    func resumeScanAfterMedia() {
        guard mediaPaused else { return }
        mediaPaused = false
        lastScanRestart = Date()
        trace("scan_resumed_media")
        scanIfNeeded()
    }

    func stop() {
        recoveryScan?.cancel(); recoveryScan = nil
        enabled = false
        mediaPaused = false
        if scanning { io.stopScan() }
        scanning = false
        for id in sessions.keys { cancel(peripheralID: id) }
        trace("scan_stopped")
    }
    func connect(peripheralID: UUID) { guard enabled, poweredOn else { return }; io.connect(peripheralID) }
    func cancel(peripheralID: UUID) { io.cancel(peripheralID) }
    func peripheral(_ id: UUID) -> CBPeripheral? { io.peripheral(id) }
    func rescan() {
        guard enabled, !mediaPaused else {
            if mediaPaused { trace("scan_reset_ignored_media") }
            return
        }
        if scanning { io.stopScan() }
        scanning = false
        lastScanRestart = Date()
        discoveredPeers.removeAll()
        trace("scan_reset")
        scanIfNeeded()
    }
    func restartDiscoveryAfterDisconnect() {
        guard enabled, poweredOn, !mediaPaused else { return }
        let remaining = 0.5 - Date().timeIntervalSince(lastRecoveryScan)
        if remaining > 0 {
            guard recoveryScan == nil else { return }
            recoveryScan = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                self?.recoveryScan = nil; self?.restartDiscoveryAfterDisconnect()
            }
            return
        }
        lastRecoveryScan = Date()
        if scanning { io.stopScan() }
        scanning = false
        scanIfNeeded() // Clear OS duplicate suppression, without cancelling another peer.
    }
    func restore(peripheralIDs: [UUID]) {
        for id in Set(peripheralIDs) where PairedAndroidDeviceStore.permitsPeripheral(id.uuidString) {
            onRestored?(id)
        }
    }

    private func trace(_ phase: String, detail: String = "", fields: [String: String] = [:]) {
        Task { await AgentVerboseTraceRecorder.shared.recordEvent(
            source: "ios", category: "voble-radio", phase: phase,
            title: "蓝牙共享扫描", detail: detail, fields: fields) }
    }

    private func adoptRestored(_ value: CBPeripheral, central: CBCentralManager) {
        guard PairedAndroidDeviceStore.permitsPeripheral(value.identifier.uuidString) else { return }
        sessions[value.identifier]?.value?.centralManager(central,
            willRestoreState: [CBCentralManagerRestoredStatePeripheralsKey: [value]])
    }
}

extension VoBLERadioController: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn { scanning = false }
        trace("radio_state", fields: ["state": String(central.state.rawValue),
                                      "authorization": String(CBManager.authorization.rawValue)])
        for slot in sessions.values { slot.value?.centralManagerDidUpdateState(central) }
        scanIfNeeded()
        if central.state == .poweredOn { onPoweredOn?() }
    }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        restore(peripheralIDs: peripherals.map(\.identifier))
        for peripheral in peripherals {
            adoptRestored(peripheral, central: central)
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard enabled else { return }
        let peer = VoBLEDiscoveredPeer(id: peripheral.identifier,
            name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "AirSIM Android",
            signal: RSSI.intValue)
        if let index = discoveredPeers.firstIndex(where: { $0.id == peer.id }) {
            if discoveredPeers[index] != peer { discoveredPeers[index] = peer }
        } else {
            discoveredPeers.append(peer)
            trace("peer_discovered", fields: ["peers": String(discoveredPeers.count),
                                              "rssi": String(peer.signal)])
        }
        onDiscovered?(peer)
        sessions[peer.id]?.value?.centralManager(central, didDiscover: peripheral,
            advertisementData: advertisementData, rssi: RSSI)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        sessions[peripheral.identifier]?.value?.centralManager(central, didConnect: peripheral)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        sessions[peripheral.identifier]?.value?.centralManager(central, didFailToConnect: peripheral, error: error)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        sessions[peripheral.identifier]?.value?.centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        sessions[peripheral.identifier]?.value?.centralManager(central, didDisconnectPeripheral: peripheral,
            timestamp: timestamp, isReconnecting: isReconnecting, error: error)
    }
}
