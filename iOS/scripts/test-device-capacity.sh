#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/airsim-device-capacity.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
python3 - "$ROOT" "$OUT" <<'PYCODE'
from pathlib import Path
import sys
root,out=map(Path,sys.argv[1:])
def section(s,a,b): return s[s.index(a):s.index(b,s.index(a))]
a=(root/'AirSIM/VoWLANAuth.swift').read_text()
# Exercise the real persistence code; the endpoint fixture is only a transport value.
(out/'Auth.swift').write_text('import Foundation\nimport CryptoKit\n'+section(a,'struct VoWLANCredential:', 'struct VoWLANSignedRequest:')+section(a,'enum VoWLANAuthError:', 'struct VoWLANRequestSigner:')+a[a.index('struct VoWLANPairingRecord:'):])
(out/'Endpoint.swift').write_text("""import Foundation
struct VoWLANEndpoint: Equatable {
 let host: String; let controlPort: UInt16; let pcmPort: UInt16; let usesTLS: Bool
 init(host: String, controlPort: UInt16, pcmPort: UInt16, usesTLS: Bool = false) throws {
 self.host=host; self.controlPort=controlPort; self.pcmPort=pcmPort; self.usesTLS=usesTLS
 }
}
""")
w=(root/'Shared/AirSIMWidgetSnapshot.swift').read_text()
models=w[:w.index('struct AirSIMWidgetStore')]
s=(root/'Shared/AirSIMLiveActivityShared.swift').read_text()
models+=section(s,'struct AirSIMCallActivityAttributes:', 'extension AirSIMCallActivityAttributes.ContentState').replace(': ActivityAttributes {','{',1)
models+=section(s,'enum LiveActivityAgentPaging {','enum LiveActivityVisualPolicy')
s=(root/'AirSIM/APIModels.swift').read_text()
models+=section(s,'struct AndroidAgentPresentation:', 'enum ModuleConnectionSummary:')
p=(root/'AirSIM/ConnectionModePreference.swift').read_text()
models+=section(p,'struct PairedAndroidDeviceRecord:', 'enum PairedAndroidDeviceStore')
s=(root/'AirSIM/LiveActivityController.swift').read_text()
models+=section(s,'struct LiveActivityAgentSnapshot:', 'enum LiveActivityStateBuilder')
(out/'Models.swift').write_text(models)
(out/'main.swift').write_text(r'''
import Foundation
let suite = "AirSIMTests.capacity." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let epoch = Date(timeIntervalSince1970: 1700000000)
for i in 0..<100 {
 let credential = try VoWLANCredential(secret: Data(repeating: UInt8(i+1), count: 32))
 VoWLANPairingRecordStore.remember(agentID: "agent-\(i)", credential: credential, endpoint: nil,
   deviceName: "Phone \(i)", defaults: defaults, now: epoch.addingTimeInterval(Double(i)))
 let saved = VoWLANPairingRecordStore.records(defaults: defaults)
 precondition(saved.count == i+1, "adding device must not evict an older pairing")
 precondition(Set(saved.map(\.agentID)).count == i+1)
}
let reopened = UserDefaults(suiteName: suite)!
precondition(VoWLANPairingRecordStore.records(defaults: reopened).count == 100)
let rotated = try VoWLANCredential(secret: Data(repeating: 250, count: 32))
VoWLANPairingRecordStore.remember(agentID: "agent-5", credential: rotated, endpoint: nil,
 deviceName: "Renamed", defaults: defaults)
precondition(VoWLANPairingRecordStore.records(defaults: defaults).count == 100)
precondition(VoWLANPairingRecordStore.records(defaults: defaults).first { $0.agentID == "agent-5" }?.deviceName == "Renamed")
VoWLANPairingRecordStore.remove(agentID: "agent-6", defaults: defaults)
precondition(VoWLANPairingRecordStore.records(defaults: defaults).count == 99)
DispatchQueue.concurrentPerform(iterations: 32) { i in
 let credential = try! VoWLANCredential(secret: Data(repeating: UInt8(i+101), count: 32))
 VoWLANPairingRecordStore.remember(agentID: "parallel-\(i)", credential: credential, endpoint: nil,
 deviceName: "Concurrent", defaults: defaults)
}
precondition(VoWLANPairingRecordStore.records(defaults: defaults).count == 131)
let sharedCredential = try VoWLANCredential(secret:Data(repeating:249,count:32))
for id in ["shared-a", "shared-b"] {
 VoWLANPairingRecordStore.remember(agentID:id, credential:sharedCredential, endpoint:nil,deviceName:id,defaults:defaults)
}
let isolated = VoWLANPairingRecordStore.records(defaults:defaults)
precondition(isolated.count == 133 && Set(isolated.map(\.id)).count == 133)
// Old secret-only record IDs still load; updating one device retains its history.
let legacySuite = suite + ".legacy"
let legacyDefaults = UserDefaults(suiteName:legacySuite)!
defer { legacyDefaults.removePersistentDomain(forName:legacySuite) }
let oldRecord = VoWLANPairingRecord(id:"legacy-fingerprint",agentID:"legacy",deviceName:"Old",createdAt:epoch,lastSeenAt:epoch,endpoints:[])
legacyDefaults.set(try JSONEncoder().encode([oldRecord]),forKey:"airsim.vowlan.pairing-records.v1")
VoWLANPairingRecordStore.remember(agentID:"legacy",credential:sharedCredential,endpoint:nil,deviceName:"New",defaults:legacyDefaults)
let migrated = VoWLANPairingRecordStore.records(defaults:legacyDefaults)
precondition(migrated.count == 1 && migrated[0].createdAt == epoch && migrated[0].deviceName == "New")
let agents = (0..<100).map { AndroidAgentPresentation(id:"agent-\($0)", deviceName:"Phone \($0)",
 phoneNumber:nil, agentKind:"standalone", cloudOnline:true, vowlanOnline:false, isCurrent:$0==99) }
let savedDevices = agents.map { PairedAndroidDeviceRecord(id:$0.id,deviceName:$0.deviceName,agentKind:$0.agentKind) }
let visible = AndroidAgentPresentation.retainingSavedDevices(Array(agents.suffix(6)), records:savedDevices)
precondition(visible.count == 100)
precondition(visible.first { $0.id == "agent-0" }?.cloudOnline == false)
precondition(visible.first { $0.id == "agent-99" }?.isCurrent == true)
var currentID: String? = nil
var cycled = Set<String>()
for _ in 0..<agents.count {
 currentID = AndroidAgentCycle.nextID(in:agents,currentID:currentID)
 precondition(currentID != nil)
 cycled.insert(currentID!)
}
precondition(cycled == Set(agents.map(\.id)))
var visited: [String] = []
for page in 0..<LiveActivityAgentPaging.pageCount(for: agents.count) {
 let snapshot = LiveActivityAgentSnapshot(agent:nil, pairedAgentCount:agents.count, agents:agents, currentID:"agent-99", page:page,
 signals:["agent-99":[.init(id:0,title:"SIM 1",signal:nil,phoneNumber:"13800000000")]])
 precondition((snapshot.currentSIMSignals ?? snapshot.agents.first(where: \.isCurrent)?.simSignals)?.first?.phoneNumber == "13800000000")
 precondition(snapshot.agents.count <= LiveActivityAgentPaging.pageSize)
 precondition(snapshot.pairedAgentCount == 100 && snapshot.deviceName == "Phone 99")
 visited += snapshot.agents.map(\.id)
 let state = AirSIMCallActivityAttributes.ContentState(callID:"",number:"",displayName:"",phase:.standby,
 startedAt:epoch,pairedAgentCount:100,agents:snapshot.agents,agentPage:snapshot.page,agentsArePage:true,agentSIMSignals:snapshot.currentSIMSignals)
 let data = try JSONEncoder().encode(state)
 precondition(data.count < 4096, "100 paired devices must not expand each ActivityKit update")
 let decoded = try JSONDecoder().decode(AirSIMCallActivityAttributes.ContentState.self, from:data)
 precondition(decoded.agentsArePage == true && decoded.agents?.map(\.id) == snapshot.agents.map(\.id))
}
// Every visible device receives its own SIM numbers, even when not selected.
let dualSignals = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, (0..<2).map { SIMSignalSummary(id:$0,title:"SIM \($0+1)",signal:nil,phoneNumber:"1380000000\($0)") }) })
let multi = LiveActivityAgentSnapshot(agent:nil,pairedAgentCount:agents.count,agents:agents,currentID:"agent-99",page:0,signals:dualSignals)
precondition(multi.agents.allSatisfy { $0.simSignals?.count == 2 })
let largestSignals = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, (0..<8).map { SIMSignalSummary(id:$0,title:"SIM \($0+1)",signal:.init(level:4,observedAtMS:Date().timeIntervalSince1970*1000),phoneNumber:String(repeating:"1",count:32)) }) })
let largest = LiveActivityAgentSnapshot(agent:nil,pairedAgentCount:agents.count,agents:agents,currentID:"agent-99",page:0,signals:largestSignals)
let largestState = AirSIMCallActivityAttributes.ContentState(callID:"",number:"",displayName:"",phase:.standby,startedAt:epoch,pairedAgentCount:100,agents:largest.agents,agentPage:largest.page,agentsArePage:true,agentSIMSignals:largest.currentSIMSignals)
print("Multi-SIM ActivityKit bytes:", try JSONEncoder().encode(largestState).count)
let largestData = try JSONEncoder().encode(largestState)
precondition(largestData.count < 4096)
precondition(visited == agents.map(\.id), "every device must be reachable through paging")
let legacy = AirSIMCallActivityAttributes.ContentState(callID:"",number:"",displayName:"",phase:.standby,startedAt:epoch)
let decodedLegacy = try JSONDecoder().decode(AirSIMCallActivityAttributes.ContentState.self, from: JSONEncoder().encode(legacy))
precondition(decodedLegacy.agentsArePage == nil)
var widget = AirSIMWidgetSnapshot.empty
widget.devices = agents.map { .init(id:$0.id,name:$0.deviceName,transport:"cloud",recentlyReachable:true,observedAt:epoch) }
let decodedWidget = try JSONDecoder().decode(AirSIMWidgetSnapshot.self, from: JSONEncoder().encode(widget))
precondition(decodedWidget.devices.count == 100)
print("Device capacity checks passed: 100 pairings, reload, rotation/removal, concurrent updates, complete paging, legacy decoding, widget roundtrip")
''')
PYCODE
xcrun swiftc "$OUT/Auth.swift" "$OUT/Endpoint.swift" "$OUT/Models.swift" "$OUT/main.swift" -o "$OUT/checks"
"$OUT/checks"
