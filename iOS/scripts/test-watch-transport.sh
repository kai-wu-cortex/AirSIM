#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/airsim-watch-transport.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
source = (root/'AirSIMWatchApp/WatchCallSession.swift').read_text()
transport = source.split('private final class WatchLocalPCMTransport:', 1)[1].split('private struct WatchDirectCallRoute', 1)[0]
transport = 'private final class WatchLocalPCMTransport:' + transport
# The transport implementation is unmodified; only the endpoint fixture is loopback-only.
harness = (root/'WatchTransportSmoke/main.swift').read_text()
(out/'main.swift').write_text(harness + '\n' + transport)
PY
xcrun swiftc -module-cache-path "$OUT/cache" "$OUT/main.swift" -o "$OUT/checks"
"$OUT/checks"
