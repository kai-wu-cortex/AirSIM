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
let stale = state.liveActivityDisplayState(isStale:true)
precondition(stale.agents?.first?.simSignals?.map(\.phoneNumber) == rows.map(\.phoneNumber))
precondition(stale.agentSIMSignals?.map(\.phoneNumber) == rows.map(\.phoneNumber))
precondition(stale.agentSIMSignals?.allSatisfy { $0.signal == nil } == true)
precondition(stale.agents?.first?.simSignals?.allSatisfy { $0.signal == nil } == true)
let data = String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)
precondition(!data.contains("sub_id") && !data.contains("subscription"))
print("SIM display checks passed: dual-SIM identity/number/signal, snapshot roundtrip, old snapshots, empty roster, expiry, zero/unknown")
''')

PY
xcrun swiftc "$OUT/Slot.swift" "$OUT/Snapshot.swift" "$OUT/main.swift" -o "$OUT/checks"
"$OUT/checks"
