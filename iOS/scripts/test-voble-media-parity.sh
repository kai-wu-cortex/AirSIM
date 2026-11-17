#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/airsim-voble-parity.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$OUT/cache" \
 "$ROOT/AirSIM/VoBLEProtocol.swift" "$ROOT/AirSIM/VoBLEMediaTransport.swift" \
 "$ROOT/VoBLERecoverySmoke/MediaParity.swift" -o "$OUT/checks"
"$OUT/checks"
