#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/airsim-sms-tests.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
source = (root/'AirSIM/APIModels.swift').read_text()
models = source[source.index('struct CallRecord:'):source.index('struct CallStatus:')]
models += source[source.index('enum SMSDirection:'):source.index('struct SMSStatus:')]
(out/'Models.swift').write_text('import Foundation\nimport CryptoKit\n' + models)
PY
xcrun swiftc "$OUT/Models.swift" "$ROOT/AirSIM/LocalHistoryStore.swift" "$ROOT/Shared/WatchCallPayload.swift" "$ROOT/SMSIdentitySmoke/main.swift" -o "$OUT/checks"
"$OUT/checks"
