"""Synthetic, offline tests. No compiler, app launch, signing key or network."""

import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("release_build", ROOT / "scripts/build-github-release.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
SHA = "a" * 40


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.plan = {"source_sha": SHA, "sequence": 42, "tag": f"main-build-42-{SHA}",
                     "archive_name": f"LessMeet-main-build-42-{SHA}-macos-arm64-adhoc.zip"}
        self.plan_path = self.root / "plan.json"
        self.plan_path.write_text(json.dumps(self.plan))
        self.output = self.root / "release"
        self.calls = []

    def git(self, args, stage, **kwargs):
        self.calls.append((args, stage))
        return "42\n" if "--count" in args else SHA + "\n"

    def test_dry_run_has_no_build_or_output_writes(self):
        with patch.object(build, "run", side_effect=self.git):
            result = build.build(self.plan_path, self.output)
        self.assertEqual(result["mode"], "dry-run")
        self.assertFalse(self.output.exists())
        self.assertTrue(all(args[0] == "git" for args, _ in self.calls))

    def test_wrong_sha_fails_before_build(self):
        with patch.object(build, "run", return_value="b" * 40):
            with self.assertRaisesRegex(build.BuildError, "merge SHA"):
                build.build(self.plan_path, self.output, execute=True)
        self.assertFalse(self.output.exists())

    def test_archive_path_injection_rejected(self):
        self.plan["archive_name"] = "../../secret.zip"
        self.plan_path.write_text(json.dumps(self.plan))
        with patch.object(build, "run") as command:
            with self.assertRaisesRegex(build.BuildError, "archive name"):
                build.build(self.plan_path, self.output)
        command.assert_not_called()

    def test_existing_output_is_never_overwritten(self):
        self.output.mkdir()
        marker = self.output / "keep"
        marker.write_text("original")
        with patch.object(build, "run", side_effect=self.git):
            with self.assertRaisesRegex(build.BuildError, "immutable"):
                build.build(self.plan_path, self.output, execute=True)
        self.assertEqual(marker.read_text(), "original")

    def test_build_failure_cannot_archive_seal_or_publish(self):
        def command(args, stage, **kwargs):
            self.calls.append(stage)
            if stage == "Local build":
                raise build.BuildError("Local build failed; no release was published.")
            if stage == "Xcode check":
                return "Xcode 26.6\nBuild version 17F113\n"
            return ""
        with patch.object(build, "load_plan", return_value=self.plan), \
             patch.object(build.platform, "system", return_value="Darwin"), \
             patch.object(build.platform, "machine", return_value="arm64"), \
             patch.object(build, "run", side_effect=command):
            with self.assertRaisesRegex(build.BuildError, "Local build failed"):
                build.build(self.plan_path, self.output, execute=True)
        self.assertNotIn("Archive", self.calls)
        self.assertNotIn("Seal release inputs", self.calls)
        self.assertFalse(self.output.exists())

    def test_toolchain_mismatch_never_builds(self):
        with patch.object(build, "load_plan", return_value=self.plan), \
             patch.object(build.platform, "system", return_value="Darwin"), \
             patch.object(build.platform, "machine", return_value="arm64"), \
             patch.object(build, "run", return_value="Xcode 26.5") as command:
            with self.assertRaisesRegex(build.BuildError, "26.6"):
                build.build(self.plan_path, self.output, execute=True)
        self.assertEqual(command.call_count, 1)

    def test_success_requires_verify_before_archive_and_seal(self):
        def command(args, stage, **kwargs):
            self.calls.append(stage)
            if stage == "Xcode check":
                return "Xcode 26.6\nBuild version 17F113\n"
            if stage == "Archive":
                self.assertTrue({"--norsrc", "--noextattr", "--noacl"} <= set(args[:-2]))
                self.assertNotIn("--sequesterRsrc", args)
                Path(args[-1]).write_bytes(b"synthetic zip")
            return ""
        def verify(app):
            self.calls.append("Verify app")
            return {"signing": "ad-hoc"}
        with patch.object(build, "load_plan", return_value=self.plan), \
             patch.object(build.platform, "system", return_value="Darwin"), \
             patch.object(build.platform, "machine", return_value="arm64"), \
             patch.object(build, "verify_app", side_effect=verify), \
             patch.object(build, "run", side_effect=command):
            result = build.build(self.plan_path, self.output, execute=True)
        self.assertEqual(result["mode"], "built")
        self.assertFalse(result["published"])
        self.assertLess(self.calls.index("Local build"), self.calls.index("Verify app"))
        self.assertLess(self.calls.index("Verify app"), self.calls.index("Archive"))
        self.assertLess(self.calls.index("Archive"), self.calls.index("Seal release inputs"))

    def test_signature_failure_cannot_archive_or_seal(self):
        def command(args, stage, **kwargs):
            self.calls.append(stage)
            return "Xcode 26.6\nBuild version 17F113\n" if stage == "Xcode check" else ""
        with patch.object(build, "load_plan", return_value=self.plan), \
             patch.object(build.platform, "system", return_value="Darwin"), \
             patch.object(build.platform, "machine", return_value="arm64"), \
             patch.object(build, "verify_app", side_effect=build.BuildError("Signature verification failed")), \
             patch.object(build, "run", side_effect=command):
            with self.assertRaisesRegex(build.BuildError, "Signature"):
                build.build(self.plan_path, self.output, execute=True)
        self.assertNotIn("Archive", self.calls)
        self.assertNotIn("Seal release inputs", self.calls)
        self.assertFalse(self.output.exists())

    def test_symlink_plan_rejected(self):
        link = self.root / "linked-plan.json"
        link.symlink_to(self.plan_path)
        with patch.object(build, "run") as command:
            with self.assertRaisesRegex(build.BuildError, "regular file"):
                build.load_plan(link)
        command.assert_not_called()

    def test_build_environment_excludes_credentials_and_forces_adhoc(self):
        with patch.dict(os.environ, {"GH_TOKEN": "never-print-this", "GITHUB_TOKEN": "secret", "GH_READ_TOKEN": "read-secret",
                                     "ASC_PRIVATE_KEY_PATH": "/private/key", "LESSMEET_SIGNING_IDENTITY": "distribution",
                                     "CLERK_SECRET_KEY": "secret", "RUNNER_TRACKING_ID": "synthetic-marker"}):
            result = build.build_environment()
        self.assertEqual(result["LESSMEET_SIGNING_IDENTITY"], "-")
        self.assertNotIn("GH_TOKEN", result)
        self.assertNotIn("GITHUB_TOKEN", result)
        self.assertNotIn("GH_READ_TOKEN", result)
        self.assertNotIn("ASC_PRIVATE_KEY_PATH", result)
        self.assertNotIn("CLERK_SECRET_KEY", result)
        self.assertEqual(result["RUNNER_TRACKING_ID"], "synthetic-marker")

    def test_child_error_is_secret_safe(self):
        result = Mock(returncode=1)
        result.communicate.return_value = ("token-in-stdout", "token-in-stderr")
        with patch.object(build.subprocess, "Popen", return_value=result):
            with self.assertRaises(build.BuildError) as error:
                build.run(["fake"], "Synthetic check")
        self.assertNotIn("token-in-", str(error.exception))

    def test_timeout_kills_only_owned_group_and_reaps_child(self):
        process = Mock(pid=12345)
        process.communicate.side_effect = subprocess.TimeoutExpired("synthetic", 1)
        with patch.object(build.subprocess, "Popen", return_value=process) as spawn, \
             patch.object(build.os, "killpg") as kill:
            with self.assertRaisesRegex(build.BuildError, "timed out"):
                build.run(["synthetic"], "Build", timeout=1)
        self.assertTrue(spawn.call_args.kwargs["start_new_session"])
        kill.assert_called_once_with(12345, build.signal.SIGKILL)
        process.wait.assert_called_once_with(timeout=10)
        process.stdout.close.assert_called_once()
        process.stderr.close.assert_called_once()

    def test_timeout_group_already_exited_still_fails_closed(self):
        process = Mock(pid=12345)
        process.communicate.side_effect = subprocess.TimeoutExpired("secret", 1)
        with patch.object(build.subprocess, "Popen", return_value=process), \
             patch.object(build.os, "killpg", side_effect=ProcessLookupError):
            with self.assertRaisesRegex(build.BuildError, "timed out") as error:
                build.run(["synthetic"], "Build", timeout=1)
        self.assertNotIn("secret", str(error.exception))
        process.wait.assert_called_once_with(timeout=10)

    def test_verify_app_rejects_wrong_architecture_and_distribution_identity(self):
        app = self.root / "LessMeet.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/LessMeet").write_bytes(b"synthetic")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "LessMeetPackagingMode": "local", "CFBundleIdentifier": "com.lessmeet.app.local",
        }))
        with patch.object(build, "run", return_value="x86_64"):
            with self.assertRaisesRegex(build.BuildError, "arm64-only"):
                build.verify_app(app)
        with patch.object(build, "run", side_effect=["arm64", "", "Authority=Developer ID Application"]):
            with self.assertRaisesRegex(build.BuildError, "ad-hoc"):
                build.verify_app(app)


if __name__ == "__main__":
    unittest.main()
