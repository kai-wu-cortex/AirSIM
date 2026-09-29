#!/bin/sh
set -eu
umask 022

# 使用 MaVo 固定提交相同的 Debian/armel 工具链，生成兼容 QDC507 soft-float ABI 的 helper。
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
source_file="$script_directory/mavo_pcm_bridge.c"
output_file="$script_directory/mavo-pcm-bridge.armv7"
builder_image=${MAVO_PCM_BUILDER_IMAGE:-"debian@sha256:19d6c1c4e66453a5d729cf13c3dcdb4708aeff1b2ed9886805afcda191f064b7"}
# 允许在 Docker Hub 不可用时复用本机已审计镜像；默认平台仍与固定 Debian 镜像一致。
builder_platform=${MAVO_PCM_BUILDER_PLATFORM:-"linux/amd64"}

command -v docker >/dev/null 2>&1 || {
    echo "构建失败：找不到 docker" >&2
    exit 1
}
test -f "$source_file" || {
    echo "构建失败：缺少 $source_file" >&2
    exit 1
}

host_uid=$(id -u)
host_gid=$(id -g)
docker run --rm --platform "$builder_platform" --entrypoint sh \
    -e HOST_UID="$host_uid" \
    -e HOST_GID="$host_gid" \
    -v "$script_directory:/src:ro" \
    -v "$script_directory:/out" \
    "$builder_image" -ec '
        # 清除基础镜像附带的第三方软件源，避免构建结果受无关仓库影响。
        rm -f /etc/apt/sources.list.d/*.list
        # 非 Debian 基础镜像先从自身官方源补齐 Debian 签名钥匙，禁止跳过仓库验签。
        if ! test -r /usr/share/keyrings/debian-archive-keyring.gpg; then
            apt-get -o Acquire::Retries=3 update
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                debian-archive-keyring
        fi
        printf "%s\n" \
            "deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://snapshot.debian.org/archive/debian/20260421T000000Z bullseye main" \
            >/etc/apt/sources.list
        apt-get -o Acquire::Check-Valid-Until=false -o Acquire::Retries=3 update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            binutils-arm-linux-gnueabi=2.35.2-2 \
            gcc-arm-linux-gnueabi=4:10.2.1-1 \
            gcc-10-arm-linux-gnueabi=10.2.1-6cross1 \
            libc6-dev-armel-cross=2.31-9cross4

        common="-std=c11 -O2 -march=armv7-a -marm -mfloat-abi=softfp -mfpu=neon -fno-pie -fstack-protector-strong -D_FORTIFY_SOURCE=2 -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow -Wformat=2 -Wstrict-prototypes -Wmissing-prototypes -Wundef -Werror"
        linker="-no-pie -Wl,-z,relro,-z,now,-z,noexecstack,--as-needed,--build-id=sha1,--export-dynamic-symbol=main"
        # shellcheck disable=SC2086
        arm-linux-gnueabi-gcc $common -pthread -fsyntax-only /src/mavo_pcm_bridge.c
        # shellcheck disable=SC2086
        arm-linux-gnueabi-gcc $common -fanalyzer -pthread -c /src/mavo_pcm_bridge.c -o /tmp/mavo_pcm_bridge.o
        # shellcheck disable=SC2086
        arm-linux-gnueabi-gcc $common -pthread /src/mavo_pcm_bridge.c $linker -ldl -o /tmp/mavo-pcm-bridge.armv7
        arm-linux-gnueabi-strip --strip-unneeded -o /out/mavo-pcm-bridge.armv7 /tmp/mavo-pcm-bridge.armv7
        arm-linux-gnueabi-readelf -h /out/mavo-pcm-bridge.armv7 | grep -q "Machine:.*ARM"
        arm-linux-gnueabi-readelf -A /out/mavo-pcm-bridge.armv7 | grep -q "Tag_CPU_arch: v7"
        ! arm-linux-gnueabi-readelf -A /out/mavo-pcm-bridge.armv7 | grep -q "Tag_ABI_VFP_args:.*VFP registers"
        # 模块原有 MaVo helper 只依赖 GLIBC_2.4；拒绝任何更高版本，防止老固件运行失败。
        required_glibc=$(arm-linux-gnueabi-readelf --version-info /out/mavo-pcm-bridge.armv7 |
            sed -n "s/.*Name: \(GLIBC_[^ ]*\).*/\1/p" | sort -u)
        test "$required_glibc" = "GLIBC_2.4"
        arm-linux-gnueabi-strings /out/mavo-pcm-bridge.armv7 | grep -qx "network PCM client connected"
        chown "$HOST_UID:$HOST_GID" /out/mavo-pcm-bridge.armv7 2>/dev/null || true
    '

chmod 755 "$output_file"
echo "构建完成：$output_file"
shasum -a 256 "$output_file"
