#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/airsim-cloud-sim.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import sys
root,out=map(Path,sys.argv[1:])
source=(root/'AirSIM/APIModels.swift').read_text()
models=source[source.index('struct CloudAndroidAgent:'):source.index('struct AndroidAgentMetadata:')]
battery=(root/'Shared/AirSIMWidgetSnapshot.swift').read_text()
battery=battery[battery.index('struct AndroidBatteryReading:'):battery.index('/// A display snapshot')]
diagnostics=(root/'AirSIM/VoIPPushController.swift').read_text()
diagnostics=diagnostics[diagnostics.index('enum CloudSelfTestStepID:'):diagnostics.index('struct CloudModeCapabilities:')]
(out/'Diagnostics.swift').write_text('import Foundation\n'+diagnostics)
(out/'Models.swift').write_text('import Foundation\n'+battery+'\nenum AirSIMWidgetSnapshot { static let freshness: TimeInterval = 300 }\n'+models)
(out/'main.swift').write_text(r'''
import Foundation
let json = #"{"cloud_online":true,"agents":[{"agent_id":"A","cloud_online":true,"sim_slots":[{"id":"opaque/1","label":"SIM 1","slot_index":0,"default":true},{"id":"opaque/2","label":"SIM 2"}]},{"agent_id":"B","cloud_online":true,"sim_slots":[]},{"agent_id":"legacy","cloud_online":true}]}"#
let status = try JSONDecoder().decode(CloudAgentStatus.self, from: Data(json.utf8))
precondition(status.agents[0].simSlots?.map(\.id) == ["opaque/1", "opaque/2"])
precondition(status.agents[0].simSlots?.first?.isDefault == true)
precondition(status.agents[0].simSlots?.first?.slotIndex == 0)
precondition(status.agents[1].simSlots == [])
precondition(status.agents[2].simSlots == nil)
let encoded = try JSONEncoder().encode(status.agents[0])
let decoded = try JSONDecoder().decode(CloudAndroidAgent.self, from: encoded)
precondition(decoded == status.agents[0])
precondition(decoded.simSlots?.last?.displayName == "SIM 2")
let androidID = "com.android.phone/com.android.services.telephony.TelephonyConnectionService\nopaque-account-2\nUserHandle{0}"
let slotJSON = try JSONSerialization.data(withJSONObject: ["id":androidID,"label":"SIM 2"])
let realSlot = try JSONDecoder().decode(AndroidSIMSlot.self, from: slotJSON)
precondition(realSlot.id == androidID)
for (slots, selected, passed) in [
    (nil as [AndroidSIMSlot]?, nil as String?, false), ([], nil, false),
    ([realSlot], androidID, true), ([realSlot], "other-agent-sim", false), ([realSlot], nil, true)
] {
    var report = CloudSelfTestReport.initial
    for step in CloudSelfTestStepID.allCases { report.update(step, state: .passed, detail: "fixture") }
    report.checkSIMRoster(slots, selectedID: selected)
    report.completedAt = Date()
    precondition(report.allPassed == passed)
    precondition(!report.copyText.contains(androidID))
}
print("Cloud SIM wire and diagnostics passed: roundtrip, empty/missing roster, exact selection, mismatch, default, identifier privacy")
''')
PY
swiftc "$OUT/Models.swift" "$OUT/Diagnostics.swift" "$OUT/main.swift" -o "$OUT/check"
"$OUT/check"
