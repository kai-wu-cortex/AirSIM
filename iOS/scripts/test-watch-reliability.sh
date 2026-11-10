#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "${WATCH_VERIFY_IPHONE_204:-0}" = "1" ]; then
    python3 "$ROOT/scripts/verify-watch-iphone-baseline.py"
fi
OUT=$(mktemp -d "${TMPDIR:-/tmp}/airsim-watch-tests.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
# Compile the exact Watch-only policy declarations without importing watchOS frameworks.
sed -n '/^\/\/ MARK: Watch-only reliability policies/,$p' "$ROOT/AirSIMWatchApp/WatchCallSession.swift" > "$OUT/policies.swift"
{ printf 'import Foundation\n'; cat "$OUT/policies.swift"; } > "$OUT/WatchPolicies.swift"
xcrun swiftc -module-cache-path "$OUT/cache" "$ROOT/Shared/WatchCallPayload.swift" "$OUT/WatchPolicies.swift" "$ROOT/WatchCallPayloadSmoke/main.swift" -o "$OUT/checks"
"$OUT/checks"
