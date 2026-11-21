#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/airsim-lan-first.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import sys
root,out=map(Path,sys.argv[1:])
s=(root/'AirSIM/VoWLANController.swift').read_text()
def section(text,a,b): return text[text.index(a):text.index(b,text.index(a))]
models=section(s,'struct VoWLANEndpoint:','enum RemoteDirectConfiguration')
# Include the production discovery value/initializer; health-response decoding is outside this policy test.
models+=section(s,'struct VoWLANDiscoveredAgent:','    func refreshed(with identity:')+'}\n'
models+=section(s,'enum VoWLANRouteCandidates {','struct VoWLANProbeGeneration')
models+=section(s,'enum VoWLANControllerError:','@MainActor\nenum VoWLANProbeRecovery')
a=(root/'AirSIM/VoWLANAuth.swift').read_text()
models+=section(a,'struct VoWLANPairingRecord:','enum VoWLANPairingRecordStore')
w=(root/'AirSIM/WiredHTTPTransport.swift').read_text()
models+=section(w,'enum LocalWiFiSubnet {','/// 模块 HTTP 响应')
p=(root/'Shared/WatchCallPayload.swift').read_text()
models+=section(p,'enum RemoteDirectHost {','struct WatchLocalPCMEndpoint:')
(out/'Models.swift').write_text('import Foundation\nimport Darwin\n'+models)
t=(root/'AirSIMTests/AirSIMTests.swift').read_text()
t=t[t.index('final class VoWLANLANFirstIntegrationTests:'):]
# This class is last in the file; fail rather than silently skip future tests.
(out/'Sources/RoutePolicy').mkdir(parents=True)
(out/'Tests/RoutePolicyTests').mkdir(parents=True)
(out/'Models.swift').rename(out/'Sources/RoutePolicy/Models.swift')
(out/'Sources/RoutePolicy/NetworkRoutePreferences.swift').write_text((root/'AirSIM/NetworkRoutePreferences.swift').read_text())
(out/'Tests/RoutePolicyTests/Checks.swift').write_text('import Foundation\nimport XCTest\n@testable import RoutePolicy\n'+t)
(out/'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "RoutePolicy", platforms: [.macOS(.v13)],
    targets: [.target(name: "RoutePolicy"), .testTarget(name: "RoutePolicyTests", dependencies: ["RoutePolicy"])])
''')
PY
# Executes production candidate selection and the same XCTest cases used on iOS.
# Does not simulate Bonjour timing, signed network authentication, or a real call.
swift test --package-path "$OUT" --jobs 2
