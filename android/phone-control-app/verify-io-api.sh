#!/bin/sh
# Check known pre-33 incompatibilities in emitted method references, not source spelling.
# This is a targeted regression gate, not a complete Android API lint replacement.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CLASSES=${1:-"$ROOT/build/android/classes"}
JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
REPORT=$(mktemp "${TMPDIR:-/tmp}/airsim-io-api.XXXXXX")
trap 'rm -f "$REPORT"' EXIT HUP INT TERM
find "$CLASSES" -name '*.class' -print0 | xargs -0 "$JAVA_HOME/bin/javap" -c -p > "$REPORT"
if grep -E 'java/io/[^ ]+\.(toString:\(Ljava/nio/charset/Charset;|readNBytes:|writeBytes:\(\[B\)|nullInputStream:)|java/util/[^ ]+\.toArray:\(Ljava/util/function/IntFunction;|java/lang/(CharSequence|StringBuilder|StringBuffer)\.isEmpty:|java/net/(URLEncoder|URLDecoder)\.(encode|decode):\(Ljava/lang/String;Ljava/nio/charset/Charset;' "$REPORT"; then
    echo 'FAIL: emitted Java calls require newer Android APIs, but AirSIM supports API 29+' >&2
    exit 1
fi
echo 'Android pre-33 Java API regression check passed'
