import os
from pathlib import Path
import shutil
import subprocess
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "tools" / "prepare-llama-simulator.sh"


@unittest.skipUnless(shutil.which("bash"), "bash is required to exercise the build script")
class SliceSelectionTests(unittest.TestCase):
    def run_script(self, value):
        environment = dict(os.environ, LLAMA_BUILD_SLICES=value)
        return subprocess.run(["bash", str(SCRIPT)], cwd=REPO, env=environment,
                              capture_output=True, text=True)

    def test_an_unknown_value_is_rejected_before_any_build(self):
        result = self.run_script("exercice")
        self.assertEqual(result.returncode, 2)
        self.assertIn("LLAMA_BUILD_SLICES", result.stderr)
        self.assertNotIn("Building", result.stdout)
