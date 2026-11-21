#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/airsim-pushkit.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
# Compile the production iPhone payload parser, excluding UIKit/network owners.
python3 - "$ROOT" "$OUT" <<'PYCODE'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
s = (root/'AirSIM/VoIPPushController.swift').read_text()
payload = s[s.index('enum VoIPPushPayloadError:'):s.index('enum CallTransport:')]
s = (root/'AirSIM/IPhoneCloudCallSession.swift').read_text()
media = s[s.index('enum CloudMediaTransport:'):s.index('enum CloudMediaTransportNegotiator')]
(out/'PhonePayload.swift').write_text('import Foundation\n'+media+payload)
PYCODE
xcrun swiftc -parse-as-library -module-cache-path "$OUT/cache" \
  "$OUT/PhonePayload.swift" "$ROOT/Shared/VoIPPushDelivery.swift" "$ROOT/Shared/WatchCallPayload.swift" \
  "$ROOT/PushKitDeliverySmoke/main.swift" -o "$OUT/checks"
"$OUT/checks"
