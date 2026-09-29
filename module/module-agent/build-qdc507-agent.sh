#!/bin/sh
set -eu

# QDC507 的 Linux 3.18/ARM 环境会让 Go 1.26 完整代理在 main 前崩溃；
# Go 1.24.13 已通过完整 Agent 的 runtime/routes/listen/at-open 实机矩阵。
go_binary=${DJONEHUB_GO:-go}
go_version=$("$go_binary" version)
case "$go_version" in
    "go version go1.24.13 "*) ;;
    *)
        echo "构建失败：必须使用 Go 1.24.13，当前为 $go_version" >&2
        exit 65
        ;;
esac

# 始终生成静态 ARMv7 Linux 程序，避免宿主机环境污染正式部署产物。
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$script_directory"
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 \
    "$go_binary" build -trimpath -ldflags='-s -w' -o qdc507-agent .

"$go_binary" version -m qdc507-agent
shasum -a 256 qdc507-agent
