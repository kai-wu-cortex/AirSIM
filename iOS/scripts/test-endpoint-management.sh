#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import sys
r,o=map(Path,sys.argv[1:])
def section(s,a,b): return s[s.index(a):s.index(b,s.index(a))]
a=(r/'AirSIM/VoWLANAuth.swift').read_text()
c=(r/'AirSIM/VoWLANController.swift').read_text()
(o/'Store.swift').write_text('import Foundation\nimport CryptoKit\n'+section(a,'struct VoWLANCredential:', 'struct VoWLANSignedRequest:')+section(a,'enum VoWLANAuthError:', 'struct VoWLANRequestSigner:')+a[a.index('struct VoWLANPairingRecord:'):]+section(c,'struct VoWLANManualRoute:', 'enum RemoteDirectConfiguration')+section(c,'enum VoWLANManualRouteStore {','struct VoWLANDiscoveredAgent:'))
(o/'Stubs.swift').write_text('''import Foundation
struct VoWLANEndpoint: Equatable {
 let host: String; let controlPort: UInt16; let pcmPort: UInt16; let usesTLS: Bool
 init(host: String, controlPort: UInt16, pcmPort: UInt16, usesTLS: Bool = false) throws {self.host=host;self.controlPort=controlPort;self.pcmPort=pcmPort;self.usesTLS=usesTLS}
}
enum VoWLANControllerError: Error {case invalidAdvertisement}
enum AndroidAgentBindingPreference {static func selected(defaults: UserDefaults) -> String? {nil}}
enum PairedAndroidDeviceStore {static func permits(_ id: String, defaults: UserDefaults) -> Bool {true}}
''')
(o/'main.swift').write_text('''import Foundation
let suite = "AirSIM.EndpointTests." + UUID().uuidString
let d = UserDefaults(suiteName: suite)!
defer { d.removePersistentDomain(forName: suite) }
let key = try VoWLANCredential(secret: Data(repeating: 7, count: 32))
let old = try VoWLANEndpoint(host: "Phone.Example.com", controlPort: 443, pcmPort: 7593, usesTLS: true)
let new = try VoWLANEndpoint(host: "phone.example.com", controlPort: 9444, pcmPort: 7593, usesTLS: true)
let lan = try VoWLANEndpoint(host: "192.168.77.1", controlPort: 8581, pcmPort: 8582)
func remember(_ id: String, _ endpoint: VoWLANEndpoint, replace: Bool = false) {
 VoWLANPairingRecordStore.remember(agentID: id, credential: key, endpoint: endpoint, deviceName: id, defaults: d, replaceSameHost: replace)
}
func record(_ id: String) -> VoWLANPairingRecord {VoWLANPairingRecordStore.records(defaults:d).first { $0.agentID == id }!}
remember("A",lan); remember("A",old); remember("B",old)
let original = record("A")
// Unverified history does not supersede a trusted endpoint.
remember("A",new)
precondition(record("A").endpoints.count == 3)
// A new authenticated port replaces just this host and transport, same device.
remember("A",new,replace:true)
precondition(record("A").endpoints.count == 2)
precondition(record("A").id == original.id && record("A").createdAt == original.createdAt)
precondition(record("B").endpoints.count == 1)
precondition(VoWLANPairingRecordStore.isExcluded(agentID:"A",endpoint:old,defaults:d))
// Late callbacks cannot resurrect the old address; other hosts/devices survive.
remember("A",old,replace:true)
precondition(record("A").endpoints.count == 2)
precondition(record("A").endpoints.last?.controlPort == 9444)
try VoWLANManualRouteStore.save(.init(agentID:"A",host:new.host,controlPort:new.controlPort,pcmPort:new.pcmPort,tls:true),defaults:d)
VoWLANPairingRecordStore.removeEndpoint(agentID:"A",endpoint:.init(new),defaults:d)
VoWLANManualRouteStore.removeEndpoint(agentID:"A",endpoint:new,defaults:d)
precondition(VoWLANManualRouteStore.selected(defaults:d) == nil)
precondition(record("A").endpoints.count == 1)
remember("A",new)
precondition(record("A").endpoints.count == 1)
let reopened = UserDefaults(suiteName:suite)!
precondition(VoWLANPairingRecordStore.isExcluded(agentID:"A",endpoint:new,defaults:reopened))
// Removing the last endpoint keeps pairing; explicit configuration can restore it.
VoWLANPairingRecordStore.removeEndpoint(agentID:"A",endpoint:.init(lan),defaults:d)
precondition(record("A").endpoints.isEmpty && record("A").id == original.id)
VoWLANPairingRecordStore.allowEndpoint(agentID:"A",endpoint:new,defaults:d)
remember("A",new,replace:true)
precondition(record("A").endpoints.count == 1)
// TLS and plaintext at the same private host are not silently merged.
VoWLANPairingRecordStore.allowEndpoint(agentID:"A",endpoint:lan,defaults:d)
remember("A",lan)
let secureLAN = try VoWLANEndpoint(host:lan.host,controlPort:443,pcmPort:7593,usesTLS:true)
remember("A",secureLAN,replace:true)
precondition(record("A").endpoints.count == 3)
print("Endpoint persistence checks passed: replacement, isolation, deletion, stale callbacks, restart, last endpoint, explicit restore, TLS separation")
''')
PY
xcrun swiftc "$OUT/Store.swift" "$OUT/Stubs.swift" "$OUT/main.swift" -o "$OUT/check"
"$OUT/check"
