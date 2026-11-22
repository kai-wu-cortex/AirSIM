#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/airsim-history-xctest.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
(out/'Sources/HistoryCore').mkdir(parents=True)
(out/'Tests/HistoryCoreTests').mkdir(parents=True)
(out/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "HistoryCore", platforms: [.macOS(.v13)],
    targets: [.target(name: "HistoryCore"), .testTarget(name: "HistoryCoreTests", dependencies: ["HistoryCore"])],
    swiftLanguageModes: [.v5])
''')
source = (root/'AirSIM/APIModels.swift').read_text()
models = source[source.index('struct CallRecord:'):source.index('struct CallStatus:')]
models += source[source.index('enum SMSDirection:'):source.index('struct SMSStatus:')]
(out/'Sources/HistoryCore/Models.swift').write_text('import Foundation\nimport CryptoKit\n'+models)
(out/'Sources/HistoryCore/LocalHistoryStore.swift').write_text((root/'AirSIM/LocalHistoryStore.swift').read_text())
tests=(root/'AirSIMTests/AirSIMTests.swift').read_text()
tests=tests[tests.index('final class HistoryAttentionTests:'):tests.index('private final class LocalPairingHTTPProbe:')]
(out/'Tests/HistoryCoreTests/HistoryTests.swift').write_text('import XCTest\n@testable import HistoryCore\n'+tests)
PY
swift test --package-path "$OUT"
