import shutil
import subprocess
import tarfile
import tempfile
import unittest
import os
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
LEGACY_COMMIT = "e02272a369dc2bf28bf8d6b030c38acddcf3add2"
FIXTURE = Path(__file__).with_name("legacy_039_core_compat_test.go.fixture")


class Legacy039CoreCompatibilityTests(unittest.TestCase):
    def test_current_core_requests_reach_legacy_modem_commands(self) -> None:
        with tempfile.TemporaryDirectory(prefix="djonehub-legacy-039-") as temporary:
            temporary_root = Path(temporary)
            archive = subprocess.run(
                ["git", "archive", LEGACY_COMMIT, "module/module-agent"],
                cwd=ROOT,
                capture_output=True,
                check=True,
            )
            with tempfile.NamedTemporaryFile(suffix=".tar") as archive_file:
                archive_file.write(archive.stdout)
                archive_file.flush()
                with tarfile.open(archive_file.name, mode="r") as source:
                    source.extractall(temporary_root, filter="data")

            agent_root = temporary_root / "module" / "module-agent"
            shutil.copy2(FIXTURE, agent_root / "legacy_039_core_compat_test.go")
            environment = os.environ.copy()
            current_agent_source = (
                ROOT / "module" / "module-agent" / "main.go"
            ).read_text(encoding="utf-8")
            current_version = re.search(
                r'agentVersion\s*=\s*"([^"]+)"', current_agent_source
            )
            self.assertIsNotNone(current_version, "无法读取当前 Agent 版本")
            environment["DJONEHUB_EXPECTED_AGENT_VERSION"] = current_version.group(1)
            environment["DJONEHUB_LEGACY_CLEANUP_PACKAGE"] = str(
                ROOT / "iPadOS" / "DJOneHub-iPad" / "Resources" /
                "module-update-cleanup.djupdate"
            )
            result = subprocess.run(
                [
                    "go", "test", "-run", "TestCurrent",
                    "-count=1", "-timeout=20s", "-v",
                ],
                cwd=agent_root,
                capture_output=True,
                text=True,
                timeout=30,
                env=environment,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(
                "--- PASS: TestCurrentAppCoreAPIWorksAgainstLegacy039",
                result.stdout,
            )
            self.assertIn(
                "--- PASS: TestCurrentCleanupPackageIsAcceptedByLegacy039Verifier",
                result.stdout,
            )


if __name__ == "__main__":
    unittest.main()
