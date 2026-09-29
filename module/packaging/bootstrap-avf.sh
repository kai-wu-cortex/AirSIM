#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
    printf 'Run as root: sudo %s <package.deb> <package.sig> <release-public.pem>\n' "$0" >&2
    exit 1
fi
if [ "$#" -ne 3 ]; then
    printf 'Usage: %s <package.deb> <package.sig> <release-public.pem>\n' "$0" >&2
    exit 2
fi

package=$1
signature=$2
public_key=$3
for required in "$package" "$signature" "$public_key"; do
    if [ ! -f "$required" ]; then
        printf 'Missing bootstrap file: %s\n' "$required" >&2
        exit 2
    fi
done

package_name=$(dpkg-deb --field "$package" Package)
architecture=$(dpkg-deb --field "$package" Architecture)
if [ "$package_name" != airsim-avf-agent ] || [ "$architecture" != arm64 ]; then
    printf 'Refusing package %s architecture %s\n' "$package_name" "$architecture" >&2
    exit 3
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/airsim-bootstrap.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
if ! base64 -d < "$signature" > "$work_dir/signature.bin" 2>/dev/null; then
    base64 -D < "$signature" > "$work_dir/signature.bin"
fi
openssl pkeyutl -verify -pubin -inkey "$public_key" -rawin \
    -in "$package" -sigfile "$work_dir/signature.bin" >/dev/null

absolute_package=$(CDPATH= cd -- "$(dirname -- "$package")" && pwd)/$(basename -- "$package")
apt-get install -y "$absolute_package"
install -d -o root -g root -m 0700 /var/lib/airsim-installerd/packages
install -o root -g root -m 0600 "$absolute_package" \
    /var/lib/airsim-installerd/packages/current.deb

printf 'AirSIM AVF Agent installed with a retained rollback package.\n'
/usr/bin/airsim-avf-pair
