#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/airsim-sim-display.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import sys
root,out=map(Path,sys.argv[1:])
s=(root/'AirSIM/APIModels.swift').read_text()
cloud=s[s.index('struct CloudAndroidAgent:'):s.index('\nstruct CloudAgentStatus:')]
(out/'Cloud.swift').write_text('import Foundation\n'+cloud)
s=s[s.index('struct AndroidSIMSlot:'):s.index('\nstruct ',s.index('struct AndroidSIMSlot:')+1)]
(out/'Slot.swift').write_text('import Foundation\n'+s)
w=(root/'Shared/AirSIMWidgetSnapshot.swift').read_text()
shared=(root/'Shared/AirSIMLiveActivityShared.swift').read_text()
activity=shared[shared.index('struct AirSIMCallActivityAttributes:'):shared.index('enum LiveActivityAgentPaging')].replace(': ActivityAttributes {','{',1)
(out/'Snapshot.swift').write_text(w[:w.index('struct AirSIMWidgetStore')]+activity)
(out/'main.swift').write_text(r'''
import Foundation
let now = Date(timeIntervalSince1970: 1795150000)
let slots = try JSONDecoder().decode([AndroidSIMSlot].self, from: Data(#"[{"id":"B","label":"second","number":"13900000002","slot_index":1,"signal":{"level":1,"observed_at_ms":1795150000000}},{"id":"A","label":"first","number":"13800000001","slot_index":0,"signal":{"level":4,"observed_at_ms":1795150000000}}]"#.utf8))
let cloudJSON = #"{"agent_id":"module-A","cloud_online":true,"signal_dbm":-73,"signal_observed_at_ms":1795150000000,"phone_number":"13800000001"}"#
var cloud = try JSONDecoder().decode(CloudAndroidAgent.self, from: Data(cloudJSON.utf8))
let moduleRows = cloud.signalSummaries(at: now)!
precondition(moduleRows.first?.signal?.level == 4 && moduleRows.first?.title == "蜂窝")
precondition(moduleRows.first?.phoneNumber == "13800000001")
precondition(cloud.signalSummaries(at: now.addingTimeInterval(300))?.first?.signal == nil)
precondition(cloud.signalSummaries(at: now.addingTimeInterval(-61))?.first?.signal == nil)
cloud.signalObservedAtMS = nil
precondition(cloud.signalSummaries(at: now) == nil, "legacy un-timestamped samples must not be made fresh")
cloud.signalObservedAtMS = 1795150000000
cloud.signalDBM = 99
precondition(cloud.signalSummaries(at: now) == nil)
cloud.signalDBM = -113
precondition(cloud.signalSummaries(at: now)?.first?.signal?.level == 0)
cloud.simSlots = slots
precondition(cloud.signalSummaries(at: now) == AndroidSIMSlot.signalSummaries(slots), "per-SIM telemetry wins")
cloud.simSlots = []
precondition(cloud.signalSummaries(at: now)?.isEmpty == true, "explicit SIM removal cannot fall back to a radio")
let offlineCloud = try JSONDecoder().decode(CloudAndroidAgent.self, from: Data(cloudJSON.replacingOccurrences(of: "true", with: "false").utf8))
precondition(offlineCloud.signalSummaries(at: now)?.first?.signal == nil)
let rows = AndroidSIMSlot.signalSummaries(slots)
precondition(rows.map(\.phoneNumber) == ["13800000001", "13900000002"])
precondition(rows.map(\.title) == ["SIM 1", "SIM 2"])
precondition(rows.map { $0.signal?.level } == [4, 1])
precondition(AndroidSIMSlot.signalSummaries(slots + slots) == rows)
precondition(AndroidSIMSlot.signalSummaries([]).isEmpty)
var snapshot = AirSIMWidgetSnapshot.preview(at: now)
snapshot.devices[0].simSignals = rows
snapshot.devices[0].phoneNumber = "13800000001"
let decoded = try JSONDecoder().decode(AirSIMWidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
precondition(decoded == snapshot)
let legacyDevice = try JSONDecoder().decode(AirSIMWidgetSnapshot.Device.self, from: Data(#"{"id":"old","name":"old","transport":"VoWLAN","recentlyReachable":true}"#.utf8))
precondition(legacyDevice.phoneNumber == nil && legacyDevice.simSignals == nil)
let old = try JSONDecoder().decode(SIMSignalSummary.self, from: Data(#"{"id":0,"title":"SIM 1"}"#.utf8))
precondition(old.phoneNumber == nil && old.signal == nil)
let legacyNumber = try JSONDecoder().decode(SIMSignalSummary.self, from: Data(#"{"id":0,"title":"SIM 1","phoneNumber":"13800000001","signal":{"level":2,"observed_at_ms":1795150000000}}"#.utf8))
precondition(legacyNumber.phoneNumber == "13800000001" && legacyNumber.signal?.level == 2)
precondition(rows[0].signal?.freshLevel(at: now.addingTimeInterval(300)) == nil)
precondition(AndroidSIMSignal(level:0,observedAtMS:1795150000000).freshLevel(at:now) == 0)
let blank = try JSONDecoder().decode(AndroidSIMSlot.self, from: Data(#"{"id":"x","label":"SIM","number":"  "}"#.utf8))
precondition(AndroidSIMSlot.signalSummaries([blank])[0].phoneNumber == nil)
// Offline/unknown measurements retain every number and its slot label.
let offline = SIMSignalSummary.displayRows(live:nil,cached:rows)
precondition(offline.map(\.phoneNumber) == rows.map(\.phoneNumber))
precondition(offline.map(\.title) == rows.map(\.title) && offline.allSatisfy { $0.signal == nil })
precondition(SIMSignalSummary.displayRows(live:[],cached:rows).isEmpty, "confirmed SIM removal clears stale identities")
let noSignal = try JSONDecoder().decode([AndroidSIMSlot].self, from: Data(#"[{"id":"a","label":"SIM","number":"13800000001","slot_index":0},{"id":"b","label":"SIM","number":"13900000002","slot_index":1}]"#.utf8))
precondition(AndroidSIMSlot.signalSummaries(noSignal).map(\.phoneNumber) == rows.map(\.phoneNumber))
let many = try JSONDecoder().decode([AndroidSIMSlot].self, from: JSONSerialization.data(withJSONObject:(0..<8).map { ["id":"card-\($0)","label":"SIM","slot_index":$0,"number":"1380000000\($0)"] }))
precondition(AndroidSIMSlot.signalSummaries(many).count == 8, "show all reported SIMs, not only the first four")
precondition(AndroidSIMSlot.signalSummaries([blank])[0].title == "卡槽未知")
let agent = AirSIMCallActivityAttributes.ContentState.AgentSummary(id:"device",name:"Phone",phoneNumber:nil,agentKind:nil,vowlanOnline:true,bluetoothOnline:false,cloudOnline:false,isCurrent:true,simSignals:rows)
let state = AirSIMCallActivityAttributes.ContentState(callID:"",number:"",displayName:"Phone",phase:.standby,startedAt:now,agents:[agent],agentSIMSignals:rows)
let stale = state.liveActivityDisplayState(isStale: true, at: now.addingTimeInterval(300))
precondition(stale.agents?.first?.simSignals?.map(\.phoneNumber) == rows.map(\.phoneNumber))
precondition(stale.agentSIMSignals?.map(\.phoneNumber) == rows.map(\.phoneNumber))
precondition(stale.agentSIMSignals?.allSatisfy { $0.signal == nil } == true)
precondition(stale.agents?.first?.simSignals?.allSatisfy { $0.signal == nil } == true)
let renewed = SIMSignalSummary(id: 1, title: "SIM 2",
    signal: .init(level: 0, observedAtMS: now.addingTimeInterval(100).timeIntervalSince1970 * 1000),
    phoneNumber: "13900000002")
var mixed = state
mixed.agentPhoneNumber = "13800000001"
mixed.agents?[0].phoneNumber = "13800000001"
mixed.agents?[0].simSignals = [renewed]
mixed.agentSIMSignals = [rows[0], renewed]
precondition(mixed.simSignalExpirationDate == now.addingTimeInterval(300), "include the current SIM when it is off-page")
let expired = mixed.liveActivityDisplayState(isStale: true, at: now.addingTimeInterval(300))
precondition(expired.phase == .standby && expired.agents?.first?.vowlanOnline == true)
precondition(expired.agentSIMSignals?[0].signal == nil && expired.agentSIMSignals?[1].signal?.level == 0)
precondition(expired.agents?.first?.simSignals?.first?.signal?.level == 0)
let hidden = mixed.hidingPhoneNumbers()
let hiddenPayload = String(decoding: try JSONEncoder().encode(hidden), as: UTF8.self)
precondition(!hiddenPayload.contains("13800000001") && !hiddenPayload.contains("13900000002"))
precondition(hidden.agentSIMSignals?[1].signal == renewed.signal && hidden.agentSIMSignals?[1].title == "SIM 2")
precondition(mixed.agents?.first?.phoneNumber == "13800000001")
// Legacy modem readings expire from their acquisition time, even without SIM rows.
let radio = AirSIMCallActivityAttributes.ContentState(callID:"", number:"", displayName:"module",
    phase:.standby, startedAt:now, transport:.vowlan, signalDBM:-80, signalObservedAt:now)
precondition(radio.simSignalExpirationDate == now.addingTimeInterval(60))
precondition(radio.freshSignalDBM(at:now.addingTimeInterval(59)) == -80)
precondition(radio.liveActivityDisplayState(isStale:false,at:now.addingTimeInterval(60)).signalDBM == nil)
precondition(radio.liveActivityDisplayState(isStale:true,at:now.addingTimeInterval(60)).phase == .standby)
precondition(radio.freshSignalDBM(at:now.addingTimeInterval(-1)) == nil)
precondition(radio.hidingPhoneNumbers().signalObservedAt == now)
let oldRadio = AirSIMCallActivityAttributes.ContentState(callID:"",number:"",displayName:"module",
    phase:.standby,startedAt:now,signalDBM:-80)
precondition(oldRadio.freshSignalDBM(at:now) == nil, "no timestamp must not imply fresh signal")
var oldJSON = try JSONSerialization.jsonObject(with:JSONEncoder().encode(radio)) as! [String:Any]
oldJSON.removeValue(forKey:"signalObservedAt")
let legacyRadio = try JSONDecoder().decode(AirSIMCallActivityAttributes.ContentState.self,
    from:JSONSerialization.data(withJSONObject:oldJSON))
precondition(legacyRadio.freshSignalDBM(at:now) == nil && legacyRadio.phase == .standby)
var both = radio
both.agentSIMSignals = [renewed]
precondition(both.simSignalExpirationDate == now.addingTimeInterval(60))
precondition(both.liveActivityDisplayState(isStale:true,at:now.addingTimeInterval(150)).agentSIMSignals?.first?.signal?.level == 0)
// Number privacy and signal visibility are independent across every device/SIM.
let visibility = AirSIMCallActivityAttributes.ContentState(callID:"",number:"2025550100",displayName:"Phone",
    phase:.standby,startedAt:now,signalDBM:-80,signalObservedAt:now,
    agentPhoneNumber:"13800000001",agents:[agent],agentSIMSignals:rows)
for numbers in [false, true] {
    for signals in [false, true] {
        let display = visibility.applyingSIMVisibility(showNumbers:numbers, showSignals:signals)
        precondition(display.agentPhoneNumber == (numbers ? visibility.agentPhoneNumber : nil))
        precondition(display.agentSIMSignals?.map(\.phoneNumber) == rows.map { numbers ? $0.phoneNumber : nil })
        precondition(display.agents?.first?.simSignals?.map(\.phoneNumber) == rows.map { numbers ? $0.phoneNumber : nil })
        precondition(display.agentSIMSignals?.map(\.signal) == rows.map { signals ? $0.signal : nil })
        precondition(display.agents?.first?.simSignals?.map(\.signal) == rows.map { signals ? $0.signal : nil })
        precondition(display.signalDBM == (signals ? -80 : nil))
        precondition(display.number == visibility.number && display.phase == visibility.phase)
        precondition(display.agentSIMSignals?.map(\.title) == rows.map(\.title))
    }
}
precondition(visibility.agentSIMSignals == rows, "presentation must not erase source telemetry")
let data = String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)
precondition(!data.contains("sub_id") && !data.contains("subscription"))
print("SIM display checks passed: dual-SIM identity/number/signal, snapshot roundtrip, old snapshots, empty roster, per-card expiry, off-page signal, independent number/signal visibility (4 combinations), legacy modem expiry and zero/unknown")
''')

PY
xcrun swiftc "$OUT/Cloud.swift" "$OUT/Slot.swift" "$OUT/Snapshot.swift" "$OUT/main.swift" -o "$OUT/checks"
"$OUT/checks"
