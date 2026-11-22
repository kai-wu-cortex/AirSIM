#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/airsim-voble-address.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import sys
root,out=map(Path,sys.argv[1:])
s=(root/'AirSIM/VoBLECentralController.swift').read_text()
s=s[s.index('actor VoBLEPairingWorker {'):s.index('@MainActor\nfinal class VoBLECommandMailbox')]
(out/'Worker.swift').write_text('import Foundation\nimport CryptoKit\nimport Security\n'+s)
PY
xcrun swiftc -parse-as-library -module-cache-path "$OUT/cache" "$ROOT/AirSIM/VoBLEPairing.swift" "$OUT/Worker.swift" "$ROOT/VoBLERecoverySmoke/AddressRecovery.swift" -o "$OUT/checks"
"$OUT/checks"
