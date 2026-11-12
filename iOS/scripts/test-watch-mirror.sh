#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/airsim-watch-mirror.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
python3 - "$ROOT" "$OUT" <<'PY'
import sys
from pathlib import Path
root, out = map(Path, sys.argv[1:])
source = (root/'AirSIM/WatchCallCoordinator.swift').read_text()
def method(signature):
    start=source.index(signature)
    brace=source.index('{',start); depth=1; i=brace+1
    while depth:
        depth += (source[i]=='{') - (source[i]=='}'); i+=1
    return source[start:i]
# Exercise production orchestration, with only framework/network boundaries replaced.
body='\n'.join(method(sig).replace('private func','func',1) for sig in [
    'private func publish(_ payload: WatchCallPayload)',
    'func consumeWatchOwnership(_ message: [String: Any]) async -> Bool'])
fixture=(root/'WatchMirrorSmoke/main.swift').read_text()
(out/'main.swift').write_text(fixture.replace('// PRODUCTION_METHODS',body))
PY
xcrun swiftc -parse-as-library -module-cache-path "$OUT/cache" "$ROOT/Shared/WatchCallPayload.swift" "$OUT/main.swift" -o "$OUT/checks"
"$OUT/checks"
