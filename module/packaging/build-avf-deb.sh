#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
version=${AIRSIM_PACKAGE_VERSION:-0.4.6}
release=${AIRSIM_PACKAGE_RELEASE:-1}
package_version="$version-$release"
dist_dir=${AIRSIM_DIST_DIR:-"$repo_root/dist"}
public_key=${AIRSIM_RELEASE_PUBLIC_KEY_BASE64:-QQPJXjO2mcx13qhv74lXen8ytjJZ2hMCz+ERlz6w5qg=}

case "$version" in
    ''|*[!0-9A-Za-z.+:~_-]*) printf 'Invalid AIRSIM_PACKAGE_VERSION: %s\n' "$version" >&2; exit 2 ;;
esac
case "$release" in
    ''|*[!0-9A-Za-z.+~]*) printf 'Invalid AIRSIM_PACKAGE_RELEASE: %s\n' "$release" >&2; exit 2 ;;
esac

build_root=$(mktemp -d "${TMPDIR:-/tmp}/airsim-deb.XXXXXX")
trap 'rm -rf "$build_root"' EXIT HUP INT TERM
package_root="$build_root/root"
control_root="$build_root/control"
mkdir -p \
    "$package_root/usr/bin" \
    "$package_root/usr/lib/airsim" \
    "$package_root/usr/lib/systemd/system" \
    "$package_root/usr/share/doc/airsim-avf-agent" \
    "$control_root" \
    "$dist_dir"

printf 'Building AirSIM AVF Agent %s for linux/arm64\n' "$package_version"
(cd "$repo_root/module/module-agent" && \
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath \
        -ldflags "-s -w -X main.agentVersion=$version" \
        -o "$package_root/usr/bin/airsim-agent" .)
(cd "$repo_root/module/avf-installerd" && \
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath \
        -ldflags "-s -w -X main.releasePublicKeyBase64=$public_key" \
        -o "$package_root/usr/lib/airsim/airsim-installerd" .)

install -m 0644 "$script_dir/debian/agent.env.default" "$package_root/usr/lib/airsim/agent.env.default"
install -m 0644 "$script_dir/debian/airsim-agent.service" "$package_root/usr/lib/systemd/system/airsim-agent.service"
install -m 0644 "$script_dir/debian/airsim-installerd.service" "$package_root/usr/lib/systemd/system/airsim-installerd.service"
install -m 0755 "$script_dir/debian/airsim-avf-pair" "$package_root/usr/bin/airsim-avf-pair"
install -m 0644 "$repo_root/LICENSE" "$package_root/usr/share/doc/airsim-avf-agent/copyright"
install -m 0644 "$repo_root/NOTICE" "$package_root/usr/share/doc/airsim-avf-agent/NOTICE"
install -m 0644 "$repo_root/THIRD_PARTY_NOTICES.md" "$package_root/usr/share/doc/airsim-avf-agent/THIRD_PARTY_NOTICES.md"
chmod 0755 "$package_root/usr/bin/airsim-agent" "$package_root/usr/lib/airsim/airsim-installerd"

installed_size=$(du -sk "$package_root" | awk '{print $1}')
cat > "$control_root/control" <<EOF
Package: airsim-avf-agent
Version: $package_version
Architecture: arm64
Maintainer: AirSIM Project <maintainers@airsim.dev>
Installed-Size: $installed_size
Depends: adduser, dpkg, systemd | systemd-sysv
Section: net
Priority: optional
Homepage: https://github.com/kai-wu-cortex/AirSIM
Description: AirSIM Agent and rescue installer for Android Virtualization Framework
 A single arm64 package for Android AVF guests. Android hardware and vendor
 differences are handled by the companion Android app capability layer.
EOF

for maintainer_script in postinst prerm postrm; do
    install -m 0755 "$script_dir/debian/$maintainer_script" "$control_root/$maintainer_script"
done

printf '2.0\n' > "$build_root/debian-binary"
COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --uname root --gname root \
    -C "$control_root" -czf "$build_root/control.tar.gz" .
COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --uname root --gname root \
    -C "$package_root" -czf "$build_root/data.tar.gz" .

package="$dist_dir/airsim-avf-agent_${package_version}_arm64.deb"
(cd "$build_root" && ar -rcS "$package" debian-binary control.tar.gz data.tar.gz)

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$dist_dir" && sha256sum "$(basename "$package")") > "$package.sha256"
else
    digest=$(shasum -a 256 "$package" | awk '{print $1}')
    printf '%s  %s\n' "$digest" "$(basename "$package")" > "$package.sha256"
fi

if [ -n "${AIRSIM_RELEASE_PRIVATE_KEY:-}" ]; then
    signature_binary="$build_root/package.sig"
    public_pem="$package.public.pem"
    openssl pkey -in "$AIRSIM_RELEASE_PRIVATE_KEY" -pubout -out "$public_pem"
    derived_public_key=$(openssl pkey -in "$AIRSIM_RELEASE_PRIVATE_KEY" -pubout -outform DER \
        | tail -c 32 | base64 | tr -d '\n')
    if [ "$derived_public_key" != "$public_key" ]; then
        printf 'AIRSIM_RELEASE_PUBLIC_KEY_BASE64 does not match AIRSIM_RELEASE_PRIVATE_KEY.\n' >&2
        exit 3
    fi
    openssl pkeyutl -sign -rawin -inkey "$AIRSIM_RELEASE_PRIVATE_KEY" \
        -in "$package" -out "$signature_binary"
    base64 < "$signature_binary" | tr -d '\n' > "$package.sig"
    printf '\n' >> "$package.sig"
	install -m 0644 "$package" "$dist_dir/airsim-avf-agent_arm64.deb"
	install -m 0644 "$package.sig" "$dist_dir/airsim-avf-agent_arm64.deb.sig"
else
    printf 'Warning: AIRSIM_RELEASE_PRIVATE_KEY is unset; detached .sig was not generated.\n' >&2
fi

install -m 0755 "$script_dir/bootstrap-avf.sh" "$dist_dir/airsim-avf-bootstrap.sh"
sed -e "s|@AIRSIM_RELEASE_PUBLIC_KEY_BASE64@|$public_key|g" \
    -e "s|@AIRSIM_PACKAGE_VERSION@|$version|g" \
    "$script_dir/install-avf.sh.in" > "$dist_dir/install-avf.sh"
chmod 0755 "$dist_dir/install-avf.sh"
sed -e "s|@AIRSIM_RELEASE_PUBLIC_KEY_BASE64@|$public_key|g" \
    -e "s|@AIRSIM_PACKAGE_VERSION@|$version|g" \
    "$script_dir/rotate-avf-key.sh.in" > "$dist_dir/rotate-avf-key.sh"
chmod 0755 "$dist_dir/rotate-avf-key.sh"
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$dist_dir" && sha256sum rotate-avf-key.sh) > "$dist_dir/rotate-avf-key.sh.sha256"
else
    digest=$(shasum -a 256 "$dist_dir/rotate-avf-key.sh" | awk '{print $1}')
    printf '%s  rotate-avf-key.sh\n' "$digest" > "$dist_dir/rotate-avf-key.sh.sha256"
fi

printf 'Created %s\n' "$package"
