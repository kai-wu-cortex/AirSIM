#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/airsim-cloud-answer-progress.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
# The progress model is Foundation-only, so the exact production file compiles on macOS.
xcrun swiftc -module-cache-path "$OUT/cache" "$ROOT/AirSIM/CloudAnswerProgress.swift" \
  "$ROOT/CloudAnswerProgressSmoke/main.swift" -o "$OUT/checks"
"$OUT/checks"
