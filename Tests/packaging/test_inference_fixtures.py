"""Fixture-generator failure checks. Speech and media commands are inert mocks."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class InferenceFixtureTests(unittest.TestCase):
    def run_fixture(self, first, second):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "scripts").mkdir()
        shutil.copy2(ROOT / "scripts/make-local-inference-fixtures.sh", root / "scripts")
        binary = root / "bin"
        binary.mkdir()
        tool = f"#!{sys.executable}\n" + '''import os, sys
from pathlib import Path
args = sys.argv[1:]
if Path(sys.argv[0]).name == "say":
    Path(args[args.index("-o") + 1]).write_bytes(b"mock speech file")
elif "volumedetect" in args:
    name = Path(args[args.index("-i") + 1]).stem
    print(os.environ["LEVEL_" + name.upper()], file=sys.stderr)
else:
    Path(args[-1]).write_bytes(b"mock derived audio")
'''
        for name in ("say", "ffmpeg"):
            path = binary / name
            path.write_text(tool)
            path.chmod(0o755)
        result = subprocess.run(["bash", "scripts/make-local-inference-fixtures.sh"],
                                cwd=root, capture_output=True, text=True,
                                env={"PATH": str(binary) + os.pathsep + os.environ["PATH"],
                                     "LEVEL_FIRST": first, "LEVEL_SECOND": second})
        fixture = next((root / ".artifacts/local-inference").iterdir())
        return result, fixture

    def test_empty_synthesis_stops_before_padding_can_hide_it(self):
        result, fixture = self.run_fixture("no samples", "max_volume: -2.0 dB")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("first has no audible samples", result.stderr)
        self.assertTrue((fixture / "first.aiff").exists())
        self.assertTrue((fixture / "first-levels.log").exists())
        self.assertFalse((fixture / "dialogue.m4a").exists())

    def test_silent_or_invalid_second_voice_stops_generation(self):
        for level in ("-91.0", "-inf", "invalid"):
            with self.subTest(level=level):
                result, fixture = self.run_fixture("max_volume: -2.0 dB", f"max_volume: {level} dB")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("second has no audible samples", result.stderr)
                self.assertFalse((fixture / "dialogue.m4a").exists())

    def test_both_audible_inputs_reach_media_generation(self):
        result, fixture = self.run_fixture("max_volume: -2.0 dB", "max_volume: -3.5 dB")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((fixture / "dialogue.m4a").exists())
        self.assertTrue((fixture / "silence.wav").exists())


if __name__ == "__main__":
    unittest.main()
