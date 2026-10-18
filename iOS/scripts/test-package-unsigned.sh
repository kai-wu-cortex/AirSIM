#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
task_tmp=$(mktemp -d /tmp/airsim-package-test.XXXXXX)
trap 'rm -rf "$task_tmp"' EXIT HUP INT TERM
app="$task_tmp/Fixture.xcarchive/Products/Applications/Fixture.app"
mkdir -p "$app/Watch/FixtureWatch.app" "$app/PlugIns/FixtureActivity.appex"
make_bundle() {
    bundle="$1"
    cp "$ROOT/fixtures/Info.plist" "$bundle/Info.plist"
    xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.3 \
        "$ROOT/fixtures/main.c" -o "$bundle/Fixture"
    codesign --remove-signature "$bundle/Fixture"
}
make_bundle "$app"
make_bundle "$app/Watch/FixtureWatch.app"
make_bundle "$app/PlugIns/FixtureActivity.appex"
# Simulate the filesystem detritus found in the previous public IPA.
touch "$app/._Fixture" "$app/.DS_Store" "$app/embedded.mobileprovision"
mkdir "$app/_CodeSignature"
touch "$app/_CodeSignature/CodeResources"
sh "$ROOT/package-unsigned.sh" "$task_tmp/Fixture.xcarchive" "$task_tmp/full.ipa" full
sh "$ROOT/package-unsigned.sh" "$app" "$task_tmp/sideload.ipa" sideload
unzip -Z1 "$task_tmp/full.ipa" > "$task_tmp/full.entries"
unzip -Z1 "$task_tmp/sideload.ipa" > "$task_tmp/sideload.entries"
grep -q '^Payload/Fixture.app/Watch/FixtureWatch.app/Fixture$' "$task_tmp/full.entries"
if grep -q '/Watch/' "$task_tmp/sideload.entries"; then exit 1; fi
for mode in full sideload; do
    grep -q '^Payload/Fixture.app/PlugIns/FixtureActivity.appex/Fixture$' "$task_tmp/$mode.entries"
    if grep -E '(^|/)(__MACOSX|\._[^/]*|\.DS_Store|_CodeSignature|embedded.mobileprovision)(/|$)' "$task_tmp/$mode.entries"; then exit 1; fi
    unzip -tq "$task_tmp/$mode.ipa"
done
test -f "$app/Watch/FixtureWatch.app/Fixture"
test -f "$app/._Fixture"
test -f "$app/embedded.mobileprovision"
mkdir "$task_tmp/unpacked"
unzip -q "$task_tmp/sideload.ipa" -d "$task_tmp/unpacked"
test -x "$task_tmp/unpacked/Payload/Fixture.app/Fixture"
# Existing artifacts and the source may not be overwritten.
if sh "$ROOT/package-unsigned.sh" "$app" "$task_tmp/full.ipa" full; then exit 1; fi
if sh "$ROOT/package-unsigned.sh" "$app" "$app/bad.ipa" sideload; then exit 1; fi
if sh "$ROOT/package-unsigned.sh" "$app" "$task_tmp/bad.ipa" unknown; then exit 1; fi
test ! -e "$task_tmp/bad.ipa"
# Signed archives need a proper export, not silent alteration of their identity.
codesign -s - "$app/Fixture"
if sh "$ROOT/package-unsigned.sh" "$app" "$task_tmp/signed.ipa" full; then exit 1; fi
test ! -e "$task_tmp/signed.ipa"
echo 'PASS: clean unsigned full/sideload packaging, extensions, permissions and source preservation'
