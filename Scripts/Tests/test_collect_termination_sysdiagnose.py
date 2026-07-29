import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "collect-termination-sysdiagnose.sh"
TERMINATION_MARKER = (
    "Checking for crash reports corresponding to unexpected termination of "
    "com.zanish-labs.ziroedge"
)


class CollectTerminationSysdiagnoseTests(unittest.TestCase):
    def run_script(self, log_contents):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            bin_directory = root / "bin"
            bin_directory.mkdir()
            invocation = root / "xcrun-invocation.txt"
            fake_xcrun = bin_directory / "xcrun"
            fake_xcrun.write_text(
                "#!/bin/bash\nprintf '%s\\n' \"$*\" > \"$FAKE_XCRUN_INVOCATION\"\n",
                encoding="utf-8",
            )
            fake_xcrun.chmod(0o755)
            ui_log = root / "ui-tests.log"
            ui_log.write_text(log_contents, encoding="utf-8")
            destination = root / "artifacts" / "sysdiagnose"
            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{bin_directory}:{environment['PATH']}",
                    "FAKE_XCRUN_INVOCATION": str(invocation),
                    "RAM_DIAGNOSTIC_SYSDIAGNOSE_TIMEOUT": "17",
                }
            )
            result = subprocess.run(
                [str(SCRIPT), str(ui_log), "device-id", str(destination)],
                capture_output=True,
                check=False,
                env=environment,
                text=True,
            )
            invocation_text = invocation.read_text() if invocation.exists() else None
            return result, invocation_text, destination

    def test_collects_full_sysdiagnose_after_unexpected_app_termination(self):
        result, invocation, destination = self.run_script(TERMINATION_MARKER)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Unexpected ZiroEdge termination detected", result.stdout)
        self.assertEqual(
            invocation,
            "devicectl device sysdiagnose --device device-id --gather-full-logs "
            f"--destination {destination} --timeout 17\n",
        )

    def test_does_not_collect_for_an_unrelated_ui_test_failure(self):
        result, invocation, _ = self.run_script("XCTAssertEqual failed")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(invocation)


if __name__ == "__main__":
    unittest.main()
