import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "deploy-qdc507-agent.py"
SPEC = importlib.util.spec_from_file_location("deploy_qdc507_agent", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def shell_function(script: str, name: str) -> str | None:
    lines = script.splitlines()
    signature = f"{name}() {{"
    if signature not in lines:
        return None
    start = lines.index(signature)
    end = next(
        index
        for index in range(start + 1, len(lines))
        if lines[index] == "}"
    )
    return "\n".join(lines[start : end + 1])


class InitScriptProcRaceTests(unittest.TestCase):
    def test_explicit_mac_marker_preserves_full_usb_profile(self):
        marker_function = shell_function(MODULE.INIT_SCRIPT, "is_explicit_mac_profile")
        self.assertIsNotNone(marker_function)

        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "usb-mode-mac"
            marker.write_text("mac\n")
            harness = Path(temporary) / "explicit-mac.sh"
            harness.write_text(
                "#!/bin/sh\n"
                f"MAC_MODE_MARKER='{marker}'\n"
                + (marker_function or "")
                + "\nis_explicit_mac_profile\n"
            )
            harness.chmod(0o755)
            result = subprocess.run([str(harness)], capture_output=True, text=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "if is_explicit_mac_profile; then",
            MODULE.INIT_SCRIPT,
            "显式 Mac 模式必须在移动模式回退前保留 serial/audio",
        )
        self.assertIn('rm -f "$MAC_MODE_MARKER"', MODULE.INIT_SCRIPT)

    def test_audio_profile_with_stale_serial_flag_falls_back_to_mobile_mode(self):
        wait_function = shell_function(MODULE.INIT_SCRIPT, "wait_mobile_profile")
        self.assertIsNotNone(wait_function)

        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            functions = temporary_path / "functions"
            serial_connected = temporary_path / "serial_connected"
            functions.write_text("diag,serial,ecm,ffs,audio\n")
            # This QDC507 reports 1 for both macOS and the affected iPhone.
            serial_connected.write_text("1\n")
            harness = temporary_path / "mobile-profile.sh"
            harness.write_text(
                "#!/bin/sh\n"
                f"FUNCTIONS='{functions}'\n"
                f"SERIAL_CONNECTED='{serial_connected}'\n"
                "sleep() { :; }\n"
                + wait_function
                + "\nwait_mobile_profile\n"
            )
            harness.chmod(0o755)
            result = subprocess.run(
                [str(harness)],
                capture_output=True,
                text=True,
            )

        self.assertEqual(
            result.returncode,
            0,
            "audio 描述符和陈旧的 serial_connected=1 不能阻止 iPhone 进入移动模式",
        )

    def test_cmdline_reads_do_not_race_shell_input_redirection(self):
        self.assertNotIn('< "/proc/$pid/cmdline"', MODULE.INIT_SCRIPT)
        self.assertIn('cat "/proc/$pid/cmdline" 2>/dev/null', MODULE.INIT_SCRIPT)

    def test_reachable_http_keeps_agent_alive_while_at_is_initializing(self):
        wait_function = shell_function(MODULE.INIT_SCRIPT, "wait_agent_health")
        self.assertIsNotNone(wait_function)

        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            busybox = temporary_path / "busybox"
            busybox.write_text("#!/bin/sh\nprintf '{\"ok\":false}\\n'\n")
            busybox.chmod(0o755)
            harness = temporary_path / "probe.sh"
            harness.write_text(
                "#!/bin/sh\n"
                "owned_agent() { return 0; }\n"
                "sleep() { :; }\n"
                + wait_function
                + "\nwait_agent_health\n"
            )
            harness.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = f"{temporary_path}:{environment['PATH']}"
            result = subprocess.run(
                [str(harness)],
                capture_output=True,
                text=True,
                env=environment,
            )

        self.assertEqual(
            result.returncode,
            0,
            "HTTP 已可达时，即使 AT 暂未健康也必须保留 Agent 控制面",
        )

    def test_confirmed_start_releases_rollback_backup_immediately(self):
        confirm_function = shell_function(MODULE.INIT_SCRIPT, "confirm_pending_update")
        self.assertIsNotNone(
            confirm_function,
            "启动脚本必须在控制面确认后立即释放旧 Agent 备份",
        )
        if confirm_function is None:
            return

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "djonehub"
            backup = root / "backup" / "app-update-123"
            log = root / "log" / "startup.log"
            backup.mkdir(parents=True)
            log.parent.mkdir(parents=True)
            (backup / "qdc507-agent").write_bytes(b"old")
            marker = root / "update-pending"
            marker.write_text(str(backup) + "\n")
            harness = Path(temporary) / "confirm.sh"
            harness.write_text(
                "#!/bin/sh\n"
                f"DATA_ROOT='{root}'\n"
                f"UPDATE_MARKER='{marker}'\n"
                f"STARTUP_LOG='{log}'\n"
                "log_startup() { printf '%s\\n' \"$*\" >>\"$STARTUP_LOG\"; }\n"
                + confirm_function
                + "\nconfirm_pending_update\n"
            )
            harness.chmod(0o755)
            result = subprocess.run([str(harness)], capture_output=True, text=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(marker.exists())
            self.assertFalse(backup.exists())
            self.assertIn("update-confirmed", log.read_text())


if __name__ == "__main__":
    unittest.main()
