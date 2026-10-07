#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/airsim-packaging.XXXXXX")
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

openssl genpkey -algorithm ED25519 -out "$test_root/release-private.pem" >/dev/null 2>&1
release_public=$(openssl pkey -in "$test_root/release-private.pem" -pubout -outform DER \
    | tail -c 32 | base64 | tr -d '\n')

AIRSIM_DIST_DIR="$test_root/dist" \
AIRSIM_PACKAGE_VERSION=0.4.4 \
AIRSIM_PACKAGE_RELEASE=1 \
AIRSIM_RELEASE_PUBLIC_KEY_BASE64="$release_public" \
AIRSIM_RELEASE_PRIVATE_KEY="$test_root/release-private.pem" \
    "$script_dir/build-avf-deb.sh"

package="$test_root/dist/airsim-avf-agent_0.4.4-1_arm64.deb"
test -f "$package"
test -f "$package.sha256"
test -f "$package.sig"
test -f "$package.public.pem"
test -x "$test_root/dist/airsim-avf-bootstrap.sh"
test -f "$test_root/dist/airsim-avf-agent_arm64.deb"
test -f "$test_root/dist/airsim-avf-agent_arm64.deb.sig"
test -x "$test_root/dist/install-avf.sh"
grep -q 'releases/download/v0.4.4' "$test_root/dist/install-avf.sh"

members=$(ar -t "$package")
printf '%s\n' "$members" | grep -qx 'debian-binary'
printf '%s\n' "$members" | grep -qx 'control.tar.gz'
printf '%s\n' "$members" | grep -qx 'data.tar.gz'

extract_dir="$test_root/extract"
mkdir -p "$extract_dir"
(cd "$extract_dir" && ar -x "$package")

control=$(tar -xOzf "$extract_dir/control.tar.gz" ./control)
printf '%s\n' "$control" | grep -qx 'Package: airsim-avf-agent'
printf '%s\n' "$control" | grep -qx 'Version: 0.4.4-1'
printf '%s\n' "$control" | grep -qx 'Architecture: arm64'

contents=$(tar -tzf "$extract_dir/data.tar.gz")
for expected in \
    './usr/bin/airsim-agent' \
    './usr/bin/airsim-avf-pair' \
    './usr/lib/airsim/airsim-installerd' \
    './usr/lib/airsim/agent.env.default' \
    './usr/lib/systemd/system/airsim-agent.service' \
    './usr/lib/systemd/system/airsim-installerd.service' \
    './usr/share/doc/airsim-avf-agent/copyright' \
    './usr/share/doc/airsim-avf-agent/NOTICE' \
    './usr/share/doc/airsim-avf-agent/THIRD_PARTY_NOTICES.md'
do
    printf '%s\n' "$contents" | grep -qx "$expected"
done

payload_dir="$test_root/payload"
mkdir -p "$payload_dir"
tar -xzf "$extract_dir/data.tar.gz" -C "$payload_dir"
file "$payload_dir/usr/bin/airsim-agent" | grep -Eq 'ARM aarch64|ARM64'
file "$payload_dir/usr/lib/airsim/airsim-installerd" | grep -Eq 'ARM aarch64|ARM64'
for script in "$script_dir"/debian/postinst "$script_dir"/debian/prerm \
    "$script_dir"/debian/postrm "$script_dir"/debian/airsim-avf-pair \
    "$script_dir"/bootstrap-avf.sh
do
    sh -n "$script"
done

install_root="$test_root/installed"
mkdir -p "$install_root/usr/bin"
install -m 0755 "$script_dir/test-fixtures/airsim-avf-pair" \
    "$install_root/usr/bin/airsim-avf-pair"
bootstrap_output=$(PATH="$script_dir/test-fixtures/fake-bin:$PATH" \
    AIRSIM_BOOTSTRAP_TEST_ROOT="$install_root" \
    AIRSIM_BOOTSTRAP_APT_LOG="$test_root/apt.log" \
    AIRSIM_RELEASE_BASE_URL="file://$test_root/dist" \
    "$test_root/dist/install-avf.sh")
grep -q 'install --reinstall -y ' "$test_root/apt.log"
printf '%s\n' "$bootstrap_output" | grep -q 'test pairing completed'
cmp "$test_root/dist/airsim-avf-agent_arm64.deb" \
    "$install_root/var/lib/airsim-installerd/packages/current.deb"

# A second run must recover/pair an existing installation instead of refusing
# to run or replacing the retained package.
printf 'unchanged second run\n' > "$test_root/apt.log"
bootstrap_output=$(PATH="$script_dir/test-fixtures/fake-bin:$PATH" \
    AIRSIM_BOOTSTRAP_TEST_ROOT="$install_root" \
    AIRSIM_BOOTSTRAP_APT_LOG="$test_root/apt.log" \
    AIRSIM_RELEASE_BASE_URL="file://$test_root/dist" \
    "$test_root/dist/install-avf.sh")
printf '%s\n' "$bootstrap_output" | grep -q '检测到已安装的 Agent'
printf '%s\n' "$bootstrap_output" | grep -q 'test pairing completed'
grep -qx 'unchanged second run' "$test_root/apt.log"

broken_root="$test_root/broken-install"
mkdir -p "$broken_root/usr/bin"
install -m 0755 "$script_dir/test-fixtures/airsim-avf-pair" \
    "$broken_root/usr/bin/airsim-avf-pair"
if PATH="$script_dir/test-fixtures/fake-bin:$PATH" \
    AIRSIM_BOOTSTRAP_TEST_ROOT="$broken_root" \
    AIRSIM_BOOTSTRAP_APT_BROKEN=1 \
    AIRSIM_BOOTSTRAP_APT_LOG="$test_root/broken-apt.log" \
    AIRSIM_RELEASE_BASE_URL="file://$test_root/dist" \
    "$test_root/dist/install-avf.sh" >"$test_root/broken-output.log" 2>&1
then
    printf 'broken Debian dependencies were accepted\n' >&2
    exit 1
fi
grep -q '未满足的系统包依赖' "$test_root/broken-output.log"
grep -qx 'check' "$test_root/broken-apt.log"
test ! -e "$broken_root/var/lib/airsim-installerd/packages/current.deb"

printf 'tampered\n' >> "$test_root/dist/airsim-avf-agent_arm64.deb"
tampered_root="$test_root/tampered-install"
mkdir -p "$tampered_root/usr/bin"
install -m 0755 "$script_dir/test-fixtures/airsim-avf-pair" \
    "$tampered_root/usr/bin/airsim-avf-pair"
if PATH="$script_dir/test-fixtures/fake-bin:$PATH" \
    AIRSIM_BOOTSTRAP_TEST_ROOT="$tampered_root" \
    AIRSIM_BOOTSTRAP_APT_LOG="$test_root/tampered-apt.log" \
    AIRSIM_RELEASE_BASE_URL="file://$test_root/dist" \
    "$test_root/dist/install-avf.sh" >/dev/null 2>&1
then
    printf 'tampered one-click package was accepted\n' >&2
    exit 1
fi
test ! -e "$test_root/tampered-apt.log"

printf 'AVF Debian packaging tests passed\n'
