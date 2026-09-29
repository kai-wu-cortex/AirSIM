import gzip
import hashlib
import importlib.util
import json
import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("build-share-package.py")
SPEC = importlib.util.spec_from_file_location("build_share_package", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
BUILD_SHARE_PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD_SHARE_PACKAGE)


class LowSpaceRecoveryTests(unittest.TestCase):
    def test_legacy_cleanup_bootstrap_is_signed_tiny_and_embedded(self) -> None:
        resources = SCRIPT_PATH.parents[3] / "iPadOS" / "DJOneHub-iPad" / "Resources"
        info = json.loads((resources / "EmbeddedModuleUpdate.json").read_text())
        cleanup = resources / "module-update-cleanup.djupdate"

        self.assertTrue(cleanup.is_file())
        self.assertEqual(hashlib.sha256(cleanup.read_bytes()).hexdigest(), info["cleanup_sha256"])
        self.assertLess(cleanup.stat().st_size, 100_000)
        with tarfile.open(cleanup, "r:gz") as archive:
            manifest = json.load(archive.extractfile("manifest.json"))
            bootstrap = archive.extractfile("payload/qdc507-agent").read()
        self.assertEqual(manifest["version"], info["version"])
        self.assertIn(b"legacy-cleanup-bootstrap-completed", bootstrap)

    def test_embedded_recovery_is_self_consistent_and_below_full_failure_peak(self) -> None:
        resources = SCRIPT_PATH.parents[3] / "iPadOS" / "DJOneHub-iPad" / "Resources"
        info = json.loads((resources / "EmbeddedModuleUpdate.json").read_text())
        recovery = resources / "module-update-recovery.djupdate"
        full = resources / "module-update.djupdate"

        self.assertEqual(hashlib.sha256(recovery.read_bytes()).hexdigest(), info["recovery_sha256"])
        self.assertEqual(hashlib.sha256(full.read_bytes()).hexdigest(), info["full_sha256"])
        with tarfile.open(recovery, "r:gz") as archive:
            manifest = json.load(archive.extractfile("manifest.json"))
            compressed_agent = archive.extractfile("payload/qdc507_voice.ko").read()
        self.assertEqual(manifest["version"], info["version"])
        self.assertEqual(gzip.decompress(compressed_agent), BUILD_SHARE_PACKAGE.AGENT.read_bytes())

        staged_payload_bytes = sum(item["size"] for item in manifest["files"])
        # 0.3.39 full updates that reached qdc507_voice.ko had already staged over
        # 7.5 MB. This bridge needs under 6.5 MB including its uploaded archive.
        self.assertLess(recovery.stat().st_size + staged_payload_bytes, 6_500_000)

    def test_recovery_refreshes_the_race_free_startup_hook(self) -> None:
        bridge = BUILD_SHARE_PACKAGE.low_space_bridge_script()
        hook = BUILD_SHARE_PACKAGE.startup_hook_script()

        self.assertIn(hook, bridge)
        self.assertIn(b'/etc/init.d/.djonehub_agent.update', bridge)
        self.assertIn(b'mv -f "$hook_tmp" /etc/init.d/djonehub_agent', bridge)
        self.assertIn(b'cat "/proc/$pid/cmdline" 2>/dev/null', hook)
        self.assertNotIn(b'< "/proc/$pid/cmdline"', hook)
        self.assertIn(
            b'busybox wget -q -T 3 -O - http://127.0.0.1:7575/api/health 2>/dev/null',
            hook,
        )

    def test_recovery_keeps_new_pcm_helper(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "data" / "djonehub"
            backup = root / "backup" / "app-update-1"
            (root / "bin").mkdir(parents=True)
            (root / "kernel").mkdir()
            (root / "voice-runtime").mkdir()
            backup.mkdir(parents=True)

            (root / "update-pending").write_text(str(backup) + "\n")
            (root / "bin" / "qdc507-agent").write_text("recovery bridge")
            (root / "kernel" / "qdc507_data11_bridge.ko").write_bytes(b"placeholder")
            (root / "voice-runtime" / "qdc507_aprv3.ko").write_bytes(b"placeholder")
            with gzip.open(root / "voice-runtime" / "qdc507_voice.ko", "wb") as compressed:
                compressed.write(b"#!/bin/sh\necho new-agent\n")
            (root / "voice-runtime" / "mavo-pcm-bridge.armv7").write_bytes(b"new-helper")

            (backup / "qdc507-agent").write_bytes(b"old-agent")
            (backup / "qdc507_data11_bridge.ko").write_bytes(b"old-data11")
            (backup / "qdc507_aprv3.ko").write_bytes(b"old-aprv3")
            (backup / "qdc507_voice.ko").write_bytes(b"old-voice")
            (backup / "mavo-pcm-bridge.armv7").write_bytes(b"old-helper")

            bridge = Path(temporary) / "recovery.sh"
            bridge.write_bytes(BUILD_SHARE_PACKAGE.low_space_bridge_script())
            bridge.chmod(0o755)
            environment = os.environ.copy()
            environment["DJONEHUB_RECOVERY_ROOT"] = str(root)
            result = subprocess.run(
                [str(bridge)],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertIn("new-agent", result.stdout)
            self.assertEqual(
                (root / "voice-runtime" / "mavo-pcm-bridge.armv7").read_bytes(),
                b"new-helper",
            )
            self.assertFalse(backup.exists())

    def test_legacy_cleanup_bootstrap_restores_old_runtime_and_removes_stale_updates(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "data" / "djonehub"
            backup = root / "backup" / "app-update-active"
            stale_backup = root / "backup" / "app-update-stale"
            stale_stage = root / ".update-stage-stale"
            temp_root = Path(temporary) / "tmp"
            (root / "bin").mkdir(parents=True)
            (root / "kernel").mkdir()
            (root / "voice-runtime").mkdir()
            (root / "log").mkdir()
            backup.mkdir(parents=True)
            stale_backup.mkdir(parents=True)
            stale_stage.mkdir()
            temp_root.mkdir()
            (temp_root / "djonehub-update-stale.tar.gz").write_bytes(b"stale")

            (root / "update-pending").write_text(str(backup) + "\n")
            (root / "bin" / "qdc507-agent").write_text("cleanup bridge")
            (root / "kernel" / "qdc507_data11_bridge.ko").write_bytes(b"placeholder")
            (root / "voice-runtime" / "qdc507_aprv3.ko").write_bytes(b"placeholder")
            (root / "voice-runtime" / "qdc507_voice.ko").write_bytes(b"placeholder")
            (root / "voice-runtime" / "mavo-pcm-bridge.armv7").write_bytes(b"new-helper")

            old_agent = b"#!/bin/sh\necho old-agent-restored\n"
            (backup / "qdc507-agent").write_bytes(old_agent)
            (backup / "qdc507_data11_bridge.ko").write_bytes(b"old-data11")
            (backup / "qdc507_aprv3.ko").write_bytes(b"old-aprv3")
            (backup / "qdc507_voice.ko").write_bytes(b"old-voice")
            (backup / "mavo-pcm-bridge.armv7").write_bytes(b"old-helper")

            bridge = Path(temporary) / "cleanup.sh"
            bridge.write_bytes(BUILD_SHARE_PACKAGE.legacy_cleanup_bridge_script())
            bridge.chmod(0o755)
            environment = os.environ.copy()
            environment["DJONEHUB_RECOVERY_ROOT"] = str(root)
            environment["DJONEHUB_RECOVERY_TMP"] = str(temp_root)
            result = subprocess.run(
                [str(bridge)],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertIn("old-agent-restored", result.stdout)
            self.assertEqual((root / "bin" / "qdc507-agent").read_bytes(), old_agent)
            self.assertEqual((root / "voice-runtime" / "qdc507_voice.ko").read_bytes(), b"old-voice")
            self.assertFalse((root / "update-pending").exists())
            self.assertFalse(backup.exists())
            self.assertFalse(stale_backup.exists())
            self.assertFalse(stale_stage.exists())
            self.assertFalse((temp_root / "djonehub-update-stale.tar.gz").exists())
            self.assertIn(
                "legacy-cleanup-bootstrap-completed",
                (root / "log" / "update.log").read_text(),
            )

    def test_cleanup_bootstrap_reclaims_diagnostic_logs_and_failed_update_payloads(self) -> None:
        """A tiny first stage must reclaim enough /data space for the recovery upload."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "data" / "djonehub"
            backup = root / "backup" / "app-update-active"
            temp_root = Path(temporary) / "tmp"
            (root / "bin").mkdir(parents=True)
            (root / "kernel").mkdir()
            (root / "voice-runtime").mkdir()
            (root / "log").mkdir()
            backup.mkdir(parents=True)
            temp_root.mkdir()

            (root / "update-pending").write_text(str(backup) + "\n")
            (root / "bin" / "qdc507-agent").write_text("cleanup bridge")
            (root / "kernel" / "qdc507_data11_bridge.ko").write_bytes(b"placeholder")
            (root / "voice-runtime" / "qdc507_aprv3.ko").write_bytes(b"placeholder")
            (root / "voice-runtime" / "qdc507_voice.ko").write_bytes(b"placeholder")
            (root / "voice-runtime" / "mavo-pcm-bridge.armv7").write_bytes(b"new-helper")

            old_agent = b"#!/bin/sh\necho old-agent-restored\n"
            (backup / "qdc507-agent").write_bytes(old_agent)
            (backup / "qdc507_data11_bridge.ko").write_bytes(b"old-data11")
            (backup / "qdc507_aprv3.ko").write_bytes(b"old-aprv3")
            (backup / "qdc507_voice.ko").write_bytes(b"old-voice")
            (backup / "mavo-pcm-bridge.armv7").write_bytes(b"old-helper")

            # These files are all disposable updater/diagnostic artifacts. On a
            # production module they can consume more than the 3 MB required by
            # the signed recovery package.
            for name in ("voice-route.log", "voice-route.log.1", "agent.log", "startup.log"):
                (root / "log" / name).write_bytes(b"x" * 1_048_576)
            (root / "bin" / "qdc507-agent.failed").write_bytes(b"failed-agent")
            (root / "bin" / "qdc507-agent.next").write_bytes(b"next-agent")

            bridge = Path(temporary) / "cleanup.sh"
            bridge.write_bytes(BUILD_SHARE_PACKAGE.legacy_cleanup_bridge_script())
            bridge.chmod(0o755)
            environment = os.environ.copy()
            environment["DJONEHUB_RECOVERY_ROOT"] = str(root)
            environment["DJONEHUB_RECOVERY_TMP"] = str(temp_root)
            subprocess.run(
                [str(bridge)],
                check=True,
                capture_output=True,
                text=True,
                env=environment,
            )

            for name in ("voice-route.log", "voice-route.log.1", "agent.log", "startup.log"):
                self.assertFalse((root / "log" / name).exists())
            self.assertFalse((root / "bin" / "qdc507-agent.failed").exists())
            self.assertFalse((root / "bin" / "qdc507-agent.next").exists())


if __name__ == "__main__":
    unittest.main()
