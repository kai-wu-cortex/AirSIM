import unittest
from pathlib import Path


DEPLOY_SCRIPT = Path(__file__).parents[1] / "deploy-qdc507-agent.py"


class StartupRecoveryLinkTests(unittest.TestCase):
    def test_healthy_start_refreshes_recovery_hard_link(self) -> None:
        source = DEPLOY_SCRIPT.read_text()

        self.assertIn('ln "$AGENT" "$RECOVERY_AGENT.next"', source)
        self.assertIn('rm -f "$RECOVERY_AGENT"', source)
        self.assertIn('mv -f "$RECOVERY_AGENT.next" "$RECOVERY_AGENT"', source)
        self.assertNotIn(
            'test -e "$RECOVERY_AGENT" || ln "$AGENT" "$RECOVERY_AGENT"',
            source,
        )


if __name__ == "__main__":
    unittest.main()
