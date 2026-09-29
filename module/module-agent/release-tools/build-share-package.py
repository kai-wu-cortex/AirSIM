#!/usr/bin/env python3
"""构建可分享的 QDC507 模块部署包与已签名运行时更新包。"""

from __future__ import annotations

import base64
import ast
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
MODULE_ROOT = ROOT / "module"
TOOLS = MODULE_ROOT / "module-agent/release-tools"
PRIVATE_KEY = ROOT / ".release-keys/module-update-ed25519.key"
PUBLIC_KEY = ROOT / ".release-keys/module-update-ed25519.pub"
AGENT_VERSION = os.environ.get("DJONEHUB_AGENT_VERSION", "0.4.2")
PACKAGE_NAME = f"DJOneHub-QDC507-Module-v{AGENT_VERSION}"
OUTPUT_ROOT = Path(
    os.environ.get("DJONEHUB_OUTPUT_ROOT", str(ROOT / "dist" / PACKAGE_NAME))
).expanduser().resolve()
APP_RESOURCES = ROOT / "iPadOS/DJOneHub-iPad/Resources"
AGENT = MODULE_ROOT / "module-agent/qdc507-agent"
BRIDGE = MODULE_ROOT / "kernel-bridge/qdc507_data11_bridge.ko"
VOICE = MODULE_ROOT / "module-agent/pcm-bridge/mavo-pcm-bridge.armv7"
VOICE_SOURCE = Path(
    os.environ.get(
        "DJONEHUB_VOICE_RUNTIME",
        str(Path.home() / "Library/Application Support/DJOneHub/voice-runtime/mavo-0443dfd"),
    )
)
LIBUSB = Path(
    os.environ.get(
        "DJONEHUB_LIBUSB",
        str(Path.home() / "Library/Application Support/DJOneHub/runtime/lib/libusb-1.0.0.dylib"),
    )
)


def startup_hook_script() -> bytes:
    """Read INIT_SCRIPT without importing the USB deployment program.

    The App update manifest must remain compatible with Agent 0.3.39, which
    accepts exactly the original five payload names.  The low-space bridge is
    therefore also responsible for refreshing the init hook after it releases
    the new Agent.  Extracting the literal from the deployer keeps one source of
    truth for the hook while avoiding import-time USB side effects.
    """
    deployer = MODULE_ROOT / "module-agent/deploy-qdc507-agent.py"
    tree = ast.parse(deployer.read_text(encoding="utf-8"), filename=str(deployer))
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        if not any(isinstance(target, ast.Name) and target.id == "INIT_SCRIPT" for target in node.targets):
            continue
        value = ast.literal_eval(node.value)
        if isinstance(value, str) and value.startswith("#!/bin/sh\n"):
            return value.encode("utf-8")
    raise RuntimeError("无法从部署器读取 INIT_SCRIPT")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_files() -> None:
    missing = [path for path in [AGENT, BRIDGE, VOICE, LIBUSB, VOICE_SOURCE / "qdc507_aprv3.ko", VOICE_SOURCE / "qdc507_voice.ko", MODULE_ROOT / "qdc507-adb-probe.py"] if not path.is_file()]
    if missing:
        raise RuntimeError("部署包缺少文件：\n" + "\n".join(str(path) for path in missing))
    if not PRIVATE_KEY.is_file() or not PUBLIC_KEY.is_file():
        raise RuntimeError("缺少发布签名私钥；请先生成 .release-keys/module-update-ed25519.key")


def sign(manifest_path: Path, signature_path: Path) -> None:
    tool = TOOLS / "ed25519-tool.swift"
    subprocess.run(["swift", str(tool), "sign", str(PRIVATE_KEY), str(manifest_path), str(signature_path)], check=True)


def low_space_bridge_script() -> bytes:
    """Return the signed one-shot bridge used when /data cannot stage the full runtime."""
    hook = startup_hook_script()
    delimiter = b"DJONEHUB_STARTUP_HOOK_EOF"
    if delimiter in hook:
        raise RuntimeError("INIT_SCRIPT 与恢复包 here-document 分隔符冲突")
    return b'''#!/bin/sh
set -eu
test "${1:-}" = "--startup-probe" && exit 0
root="${DJONEHUB_RECOVERY_ROOT:-/data/djonehub}"
marker="$root/update-pending"
backup=$(sed -n '1p' "$marker")
case "$backup" in /data/djonehub/backup/app-update-*|"$root"/backup/app-update-*) ;; *) exit 70;; esac
test -d "$backup"
payload="$root/voice-runtime/qdc507_voice.ko"
voice="$root/voice-runtime/qdc507_voice.ko"
next="$root/bin/qdc507-agent.next"
test -f "$backup/qdc507-agent"
test -f "$backup/qdc507_data11_bridge.ko"
test -f "$backup/qdc507_aprv3.ko"
test -f "$backup/qdc507_voice.ko"
test -f "$backup/mavo-pcm-bridge.armv7"
rm -f "$next"
rm -f "$backup/qdc507-agent"
gzip -dc "$payload" >"$next"
chmod 755 "$next"
mv "$backup/qdc507_data11_bridge.ko" "$root/kernel/qdc507_data11_bridge.ko"
mv "$backup/qdc507_aprv3.ko" "$root/voice-runtime/qdc507_aprv3.ko"
mv "$backup/qdc507_voice.ko" "$voice"
# The recovery archive already installed the new helper before this bridge ran.
# Discard the old backup instead of overwriting the new helper with it.
rm -f "$backup/mavo-pcm-bridge.armv7"
rm -f "$marker"
rm -rf "$backup"
mv "$next" "$root/bin/qdc507-agent"
if test "$root" = "/data/djonehub"; then
  hook_tmp=/etc/init.d/.djonehub_agent.update
  hook_ok=0
  if cat >"$hook_tmp" <<'DJONEHUB_STARTUP_HOOK_EOF'
''' + hook + b'''DJONEHUB_STARTUP_HOOK_EOF
  then
    if chmod 755 "$hook_tmp" && mv -f "$hook_tmp" /etc/init.d/djonehub_agent; then
      rm -f /etc/rc5.d/S99djonehub_agent || true
      if ln -sfn ../init.d/djonehub_agent /etc/rc5.d/S99zz_djonehub_agent; then
        hook_ok=1
      fi
    fi
  fi
  rm -f "$hook_tmp" || true
  if test "$hook_ok" != 1; then
    mkdir -p "$root/log"
    printf 'startup-hook-refresh-warning\n' >>"$root/log/update.log"
  fi
  exec /data/djonehub/bin/qdc507-agent
fi
exec "$root/bin/qdc507-agent"
'''


def legacy_cleanup_bridge_script() -> bytes:
    """Return a tiny signed bridge that lets 0.3.39 free stale updater files.

    The legacy updater verifies and atomically installs this bundle using its
    existing Ed25519 trust root. On restart the bridge restores the untouched
    legacy runtime from the updater backup, deletes stale updater-owned paths,
    then execs the restored Agent. A second recovery upload can consequently
    use the reclaimed space without requiring a Mac.
    """
    return b'''#!/bin/sh
set -eu
test "${1:-}" = "--startup-probe" && exit 0
root="${DJONEHUB_RECOVERY_ROOT:-/data/djonehub}"
tmp="${DJONEHUB_RECOVERY_TMP:-/data/local/tmp}"
marker="$root/update-pending"
backup=$(sed -n '1p' "$marker")
case "$backup" in /data/djonehub/backup/app-update-*|"$root"/backup/app-update-*) ;; *) exit 70;; esac
test -d "$backup"
test -f "$backup/qdc507-agent"
test -f "$backup/qdc507_data11_bridge.ko"
test -f "$backup/qdc507_aprv3.ko"
test -f "$backup/qdc507_voice.ko"
test -f "$backup/mavo-pcm-bridge.armv7"
rm -f "$root/kernel/qdc507_data11_bridge.ko"
mv "$backup/qdc507_data11_bridge.ko" "$root/kernel/qdc507_data11_bridge.ko"
rm -f "$root/voice-runtime/qdc507_aprv3.ko"
mv "$backup/qdc507_aprv3.ko" "$root/voice-runtime/qdc507_aprv3.ko"
rm -f "$root/voice-runtime/qdc507_voice.ko"
mv "$backup/qdc507_voice.ko" "$root/voice-runtime/qdc507_voice.ko"
rm -f "$root/voice-runtime/mavo-pcm-bridge.armv7"
mv "$backup/mavo-pcm-bridge.armv7" "$root/voice-runtime/mavo-pcm-bridge.armv7"
rm -f "$root/bin/qdc507-agent"
mv "$backup/qdc507-agent" "$root/bin/qdc507-agent"
chmod 755 "$root/bin/qdc507-agent" "$root/voice-runtime/mavo-pcm-bridge.armv7"
rm -f "$marker"
rm -rf "$backup"
rm -rf "$root"/.update-stage-* "$root"/backup/app-update-* "$tmp"/djonehub-update-*.tar.gz
# Diagnostic logs and orphaned updater payloads are disposable. Remove them in
# this tiny first stage so modules with less than one recovery-package worth of
# free space can accept the signed second stage without a Mac.
rm -f "$root"/log/voice-route.log "$root"/log/voice-route.log.1 \
  "$root"/log/agent.log "$root"/log/startup.log \
  "$root"/bin/qdc507-agent.failed "$root"/bin/qdc507-agent.next
mkdir -p "$root/log"
printf 'legacy-cleanup-bootstrap-completed\n' >>"$root/log/update.log"
exec "$root/bin/qdc507-agent"
'''


def write_legacy_cleanup_bundle(output: Path) -> None:
    """Build the signed first stage accepted by the unmodified 0.3.39 updater."""
    bridge = legacy_cleanup_bridge_script()
    with tempfile.TemporaryDirectory(prefix="djonehub-cleanup-") as temporary:
        temporary_root = Path(temporary)
        bridge_path = temporary_root / "qdc507-agent"
        bridge_path.write_bytes(bridge)
        placeholder = temporary_root / "cleanup-placeholder"
        placeholder.write_bytes(b"\0")
        files = [
            ("qdc507-agent", bridge_path, "bin/qdc507-agent", 0o755),
            ("qdc507_data11_bridge.ko", placeholder, "kernel/qdc507_data11_bridge.ko", 0o644),
            ("qdc507_aprv3.ko", placeholder, "voice-runtime/qdc507_aprv3.ko", 0o644),
            ("qdc507_voice.ko", placeholder, "voice-runtime/qdc507_voice.ko", 0o644),
            ("mavo-pcm-bridge.armv7", VOICE, "voice-runtime/mavo-pcm-bridge.armv7", 0o755),
        ]
        manifest = {
            "format_version": 1,
            "version": AGENT_VERSION,
            "platform": "qdc507-armv7-linux-3.18.44",
            "files": [
                {"name": name, "target": target, "sha256": sha256(source), "size": source.stat().st_size, "mode": mode}
                for name, source, target, mode in files
            ],
        }
        manifest_bytes = (json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()
        manifest_path = temporary_root / "manifest.json"
        signature_path = temporary_root / "manifest.sig"
        manifest_path.write_bytes(manifest_bytes)
        sign(manifest_path, signature_path)
        with output.open("wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                    def add_bytes(name: str, payload: bytes, mode: int) -> None:
                        info = tarfile.TarInfo(name)
                        info.size = len(payload)
                        info.mode = mode
                        info.mtime = 0
                        archive.addfile(info, __import__("io").BytesIO(payload))

                    add_bytes("manifest.json", manifest_bytes, 0o644)
                    add_bytes("manifest.sig", signature_path.read_bytes(), 0o644)
                    for name, source, _, mode in files:
                        info = tarfile.TarInfo("payload/" + name)
                        info.size = source.stat().st_size
                        info.mode = mode
                        info.mtime = 0
                        with source.open("rb") as handle:
                            archive.addfile(info, handle)


def write_low_space_recovery_bundle(output: Path) -> None:
    """Build a small signed bridge that frees the old Agent before expansion."""
    bridge = low_space_bridge_script()
    with tempfile.TemporaryDirectory(prefix="djonehub-low-space-") as temporary:
        temporary_root = Path(temporary)
        compressed_agent = temporary_root / "qdc507-agent.gz"
        with AGENT.open("rb") as source, compressed_agent.open("wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as compressed:
                shutil.copyfileobj(source, compressed)
        bridge_path = temporary_root / "qdc507-agent"
        bridge_path.write_bytes(bridge)
        placeholder = temporary_root / "recovery-placeholder"
        placeholder.write_bytes(b"\0")
        files = [
            ("qdc507-agent", bridge_path, "bin/qdc507-agent", 0o755),
            ("qdc507_data11_bridge.ko", placeholder, "kernel/qdc507_data11_bridge.ko", 0o644),
            ("qdc507_aprv3.ko", placeholder, "voice-runtime/qdc507_aprv3.ko", 0o644),
            ("qdc507_voice.ko", compressed_agent, "voice-runtime/qdc507_voice.ko", 0o644),
            ("mavo-pcm-bridge.armv7", VOICE, "voice-runtime/mavo-pcm-bridge.armv7", 0o755),
        ]
        manifest = {
            "format_version": 1,
            "version": AGENT_VERSION,
            "platform": "qdc507-armv7-linux-3.18.44",
            "files": [
                {"name": name, "target": target, "sha256": sha256(source), "size": source.stat().st_size, "mode": mode}
                for name, source, target, mode in files
            ],
        }
        manifest_bytes = (json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()
        manifest_path = temporary_root / "manifest.json"
        signature_path = temporary_root / "manifest.sig"
        manifest_path.write_bytes(manifest_bytes)
        sign(manifest_path, signature_path)
        with output.open("wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                    def add_bytes(name: str, payload: bytes, mode: int) -> None:
                        info = tarfile.TarInfo(name)
                        info.size = len(payload)
                        info.mode = mode
                        info.mtime = 0
                        archive.addfile(info, __import__("io").BytesIO(payload))

                    add_bytes("manifest.json", manifest_bytes, 0o644)
                    add_bytes("manifest.sig", signature_path.read_bytes(), 0o644)
                    for name, source, _, mode in files:
                        info = tarfile.TarInfo("payload/" + name)
                        info.size = source.stat().st_size
                        info.mode = mode
                        info.mtime = 0
                        with source.open("rb") as handle:
                            archive.addfile(info, handle)


def write_update_bundle(output: Path) -> dict[str, object]:
    files = [
        ("qdc507-agent", AGENT, "bin/qdc507-agent", 0o755),
        ("qdc507_data11_bridge.ko", BRIDGE, "kernel/qdc507_data11_bridge.ko", 0o644),
        ("qdc507_aprv3.ko", VOICE_SOURCE / "qdc507_aprv3.ko", "voice-runtime/qdc507_aprv3.ko", 0o644),
        ("qdc507_voice.ko", VOICE_SOURCE / "qdc507_voice.ko", "voice-runtime/qdc507_voice.ko", 0o644),
        ("mavo-pcm-bridge.armv7", VOICE, "voice-runtime/mavo-pcm-bridge.armv7", 0o755),
    ]
    manifest = {
        "format_version": 1,
        "version": AGENT_VERSION,
        "platform": "qdc507-armv7-linux-3.18.44",
        "files": [
            {"name": name, "target": target, "sha256": sha256(source), "size": source.stat().st_size, "mode": mode}
            for name, source, target, mode in files
        ],
    }
    manifest_bytes = (json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()
    with tempfile.TemporaryDirectory(prefix="djonehub-update-") as temporary:
        manifest_path = Path(temporary) / "manifest.json"
        signature_path = Path(temporary) / "manifest.sig"
        manifest_path.write_bytes(manifest_bytes)
        sign(manifest_path, signature_path)
        with output.open("wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                    def add_bytes(name: str, payload: bytes, mode: int) -> None:
                        info = tarfile.TarInfo(name)
                        info.size = len(payload)
                        info.mode = mode
                        info.mtime = 0
                        archive.addfile(info, __import__("io").BytesIO(payload))

                    add_bytes("manifest.json", manifest_bytes, 0o644)
                    add_bytes("manifest.sig", signature_path.read_bytes(), 0o644)
                    for name, source, _, mode in files:
                        info = tarfile.TarInfo("payload/" + name)
                        info.size = source.stat().st_size
                        info.mode = mode
                        info.mtime = 0
                        with source.open("rb") as handle:
                            archive.addfile(info, handle)
    return manifest


def patched_probe(destination: Path) -> None:
    source = (MODULE_ROOT / "qdc507-adb-probe.py").read_text(encoding="utf-8")
    old = 'LIBUSB_PATH = Path(\n    "/Users/jieden/Library/Application Support/DJOneHub/runtime/lib/libusb-1.0.0.dylib"\n)'
    current = 'str(Path.home() / "Library/Application Support/DJOneHub/runtime/lib/libusb-1.0.0.dylib")'
    packaged = 'str(Path(__file__).resolve().parent / "runtime/libusb-1.0.0.dylib")'
    if old in source:
        source = source.replace("import ctypes\n", "import ctypes\nimport os\n", 1)
        source = source.replace(
            old,
            'LIBUSB_PATH = Path(os.environ.get("DJONEHUB_LIBUSB", '
            + packaged
            + '))',
        )
    elif current in source:
        source = source.replace(current, packaged, 1)
    else:
        raise RuntimeError("qdc507-adb-probe.py 的 libusb 路径格式发生变化，拒绝静默打包")
    destination.write_text(source, encoding="utf-8")


def write_package(
    manifest: dict[str, object],
    update_bundle: Path,
    recovery_bundle: Path,
    cleanup_bundle: Path,
) -> None:
    if OUTPUT_ROOT.exists():
        raise RuntimeError(f"输出目录已存在，为避免覆盖用户文件请先移走：{OUTPUT_ROOT}")
    (OUTPUT_ROOT / "module-agent/voice-runtime").mkdir(parents=True)
    (OUTPUT_ROOT / "module-agent/pcm-bridge").mkdir(parents=True)
    (OUTPUT_ROOT / "kernel-bridge").mkdir(parents=True)
    (OUTPUT_ROOT / "runtime").mkdir(parents=True)
    shutil.copy2(AGENT, OUTPUT_ROOT / "module-agent/qdc507-agent")
    shutil.copy2(MODULE_ROOT / "module-agent/deploy-qdc507-agent.py", OUTPUT_ROOT / "module-agent/deploy-qdc507-agent.py")
    shutil.copy2(BRIDGE, OUTPUT_ROOT / "kernel-bridge/qdc507_data11_bridge.ko")
    shutil.copy2(VOICE, OUTPUT_ROOT / "module-agent/pcm-bridge/mavo-pcm-bridge.armv7")
    shutil.copy2(VOICE_SOURCE / "qdc507_aprv3.ko", OUTPUT_ROOT / "module-agent/voice-runtime/qdc507_aprv3.ko")
    shutil.copy2(VOICE_SOURCE / "qdc507_voice.ko", OUTPUT_ROOT / "module-agent/voice-runtime/qdc507_voice.ko")
    shutil.copy2(LIBUSB, OUTPUT_ROOT / "runtime/libusb-1.0.0.dylib")
    patched_probe(OUTPUT_ROOT / "qdc507-adb-probe.py")
    shutil.copy2(update_bundle, OUTPUT_ROOT / "module-update.djupdate")
    shutil.copy2(recovery_bundle, OUTPUT_ROOT / "module-update-recovery.djupdate")
    shutil.copy2(cleanup_bundle, OUTPUT_ROOT / "module-update-cleanup.djupdate")
    (OUTPUT_ROOT / "install.command").write_text(
        "#!/bin/sh\nset -eu\ncd \"$(dirname \"$0\")\"\nexec python3 module-agent/deploy-qdc507-agent.py --confirm-persistent-deploy\n",
        encoding="utf-8",
    )
    (OUTPUT_ROOT / "install.command").chmod(0o755)
    (OUTPUT_ROOT / "README.txt").write_text(
        f"""DJOneHub QDC507 模块部署包 v{AGENT_VERSION}

使用条件：macOS、Python 3、支持数据传输的 USB 线、已验证的 QDC507（USB ID 2c7c:0125）。

首次配置：
1. 退出 Mac 版 DJOneHub，避免 USB ADB 接口被占用。
2. 保持模块为 Mac 完整模式并接入 Mac。
3. 双击 install.command，按终端提示完成一次性部署。
4. 部署成功后，将模块插入已安装并授权 DJOneHub 的 iPad。

部署器会校验模块身份、原厂服务 PID、语音运行时 SHA-256 和 Agent 启动探针；任何一项不匹配都会拒绝写入。
三个 App 内更新包均由内嵌 Ed25519 公钥验证：
- module-update-cleanup.djupdate：供 0.3.39 先清理旧安装残留；
- module-update-recovery.djupdate：低空间自释放恢复包；
- module-update.djupdate：空间充足时使用的完整原子包。
App 会自动选择安装路径，并在新 Agent 启动失败时保留或恢复旧运行时。

限制：仅限 PolyForm Noncommercial License 允许的非商业用途。请确认语音内核文件具有再分发授权。
""",
        encoding="utf-8",
    )
    info = {
        "version": AGENT_VERSION,
        "platform": manifest["platform"],
        "public_key": base64.b64encode(PUBLIC_KEY.read_bytes()).decode(),
        "full_sha256": sha256(update_bundle),
        "recovery_sha256": sha256(recovery_bundle),
        "cleanup_sha256": sha256(cleanup_bundle),
    }
    (OUTPUT_ROOT / "EmbeddedModuleUpdate.json").write_text(json.dumps(info, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    checksum_lines = []
    for path in sorted(item for item in OUTPUT_ROOT.rglob("*") if item.is_file() and item.name != "SHA256SUMS"):
        checksum_lines.append(f"{sha256(path)}  {path.relative_to(OUTPUT_ROOT)}")
    (OUTPUT_ROOT / "SHA256SUMS").write_text("\n".join(checksum_lines) + "\n", encoding="utf-8")


def sync_app_resources(
    manifest: dict[str, object],
    update_bundle: Path,
    recovery_source: Path,
    cleanup_source: Path,
) -> None:
    """同步 App 内置更新，保证首次接入检测到的新版本一定有对应升级包。"""
    APP_RESOURCES.mkdir(parents=True, exist_ok=True)
    full_bundle = APP_RESOURCES / "module-update.djupdate"
    recovery_bundle = APP_RESOURCES / "module-update-recovery.djupdate"
    cleanup_bundle = APP_RESOURCES / "module-update-cleanup.djupdate"
    shutil.copy2(update_bundle, full_bundle)
    shutil.copy2(recovery_source, recovery_bundle)
    shutil.copy2(cleanup_source, cleanup_bundle)
    info = {
        "version": AGENT_VERSION,
        "platform": manifest["platform"],
        "public_key": base64.b64encode(PUBLIC_KEY.read_bytes()).decode(),
        "full_sha256": sha256(full_bundle),
        "recovery_sha256": sha256(recovery_bundle),
        "cleanup_sha256": sha256(cleanup_bundle),
    }
    (APP_RESOURCES / "EmbeddedModuleUpdate.json").write_text(
        json.dumps(info, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    # A signed manifest must never wrap a stale binary from an earlier build.
    # Build the ARMv7 Agent from the current source before hashing or signing.
    subprocess.run(
        [str(MODULE_ROOT / "module-agent/build-qdc507-agent.sh")],
        cwd=MODULE_ROOT / "module-agent",
        check=True,
    )
    require_files()
    OUTPUT_ROOT.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="djonehub-package-") as temporary:
        update_bundle = Path(temporary) / "module-update.djupdate"
        recovery_bundle = Path(temporary) / "module-update-recovery.djupdate"
        cleanup_bundle = Path(temporary) / "module-update-cleanup.djupdate"
        manifest = write_update_bundle(update_bundle)
        write_low_space_recovery_bundle(recovery_bundle)
        write_legacy_cleanup_bundle(cleanup_bundle)
        write_package(manifest, update_bundle, recovery_bundle, cleanup_bundle)
        sync_app_resources(manifest, update_bundle, recovery_bundle, cleanup_bundle)
    print(f"已生成分享包：{OUTPUT_ROOT}")
    print(f"签名更新包：{OUTPUT_ROOT / 'module-update.djupdate'}")


if __name__ == "__main__":
    main()
