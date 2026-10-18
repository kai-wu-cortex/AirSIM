#!/bin/sh
# Package CODE_SIGNING_ALLOWED=NO archives only. No credentials or signing identities.
set -eu
fail() { echo "error: $*" >&2; exit 1; }
test "$#" -eq 3 || fail 'usage: package-unsigned.sh INPUT.app|INPUT.xcarchive OUTPUT.ipa full|sideload'
input="$1"
output="$2"
mode="$3"
case "$mode" in full|sideload) ;; *) fail 'mode must be full or sideload' ;; esac
test -d "$input" || fail 'input is not a directory'
input=$(CDPATH= cd -- "$input" && pwd -P)
case "$input" in
    *.xcarchive)
        count=0
        for candidate in "$input/Products/Applications/"*.app; do
            test -d "$candidate" || continue
            app="$candidate"
            count=$((count + 1))
        done
        test "$count" -eq 1 || fail 'archive must contain exactly one top-level app'
        ;;
    *.app) app="$input" ;;
    *) fail 'input must be an .app or .xcarchive' ;;
esac
test -d "$(dirname -- "$output")" || fail 'output directory does not exist'
output_dir=$(CDPATH= cd -- "$(dirname -- "$output")" && pwd -P)
output="$output_dir/$(basename -- "$output")"
case "$output" in "$input"/*|"$app"/*) fail 'output must be outside the source' ;; esac
case "$output" in *.ipa) ;; *) fail 'output must end in .ipa' ;; esac
test ! -e "$output" && test ! -L "$output" || fail 'output already exists; choose a new path'

task_tmp=$(mktemp -d /tmp/airsim-unsigned-package.XXXXXX)
trap 'rm -rf "$task_tmp"' EXIT HUP INT TERM
mkdir "$task_tmp/Payload"
staged="$task_tmp/Payload/$(basename -- "$app")"
ditto --norsrc --noextattr --noqtn --noacl "$app" "$staged"
# A full package keeps Watch. The sideload variant changes only this staged copy.
if test "$mode" = sideload; then rm -rf "$staged/Watch"; fi
find "$staged" -type d \( -name '*.app' -o -name '*.appex' -o -name '*.framework' \) \
    -print > "$task_tmp/bundles"
while IFS= read -r bundle; do
    executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Info.plist")
    case "$executable" in ''|*/*|.|..) fail 'invalid bundle executable' ;; esac
    test -f "$bundle/$executable" && test -x "$bundle/$executable" || fail 'bundle executable missing or not executable'
    if codesign -d "$bundle/$executable" >/dev/null 2>&1; then
        fail 'input contains signed code; build an unsigned archive or export using Xcode'
    fi
done < "$task_tmp/bundles"
find "$staged" -type f -name '*.dylib' -print > "$task_tmp/libraries"
while IFS= read -r library; do
    if codesign -d "$library" >/dev/null 2>&1; then fail 'input contains a signed library'; fi
done < "$task_tmp/libraries"
# All removals below are confined to the newly created private staging directory.
find "$staged" -type f \( -name '._*' -o -name '.DS_Store' -o -name embedded.mobileprovision \) -delete
find "$staged" -type d \( -name _CodeSignature -o -name __MACOSX \) -prune -exec rm -rf {} +
COPYFILE_DISABLE=1 ditto --norsrc --noextattr --noqtn --noacl -c -k --keepParent \
    "$task_tmp/Payload" "$task_tmp/package.ipa"
unzip -tq "$task_tmp/package.ipa" >/dev/null
unzip -Z1 "$task_tmp/package.ipa" > "$task_tmp/entries"
if grep -Eq '(^|/)(__MACOSX|\._[^/]*|\.DS_Store|_CodeSignature|embedded.mobileprovision)(/|$)' "$task_tmp/entries"; then
    fail 'unexpected signing or macOS metadata in package'
fi
# Do not replace an existing file, including if another build published it meanwhile.
cp -n "$task_tmp/package.ipa" "$output"
cmp -s "$task_tmp/package.ipa" "$output" || fail 'output was created concurrently'
echo "Created unsigned $mode IPA: $output (must be re-signed before installation)"
