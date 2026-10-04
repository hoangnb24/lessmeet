"""Offline packaging tests. Swift and signing calls use inert test doubles."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PUBLIC = {"CLERK_PUBLISHABLE_KEY": "pk_test_c3ludGhldGlj",
          "CONVEX_SITE_URL": "https://synthetic.convex.site"}
PROPERTIES = ("ClerkPublishableKey", "ConvexSiteURL", "RevenueCatPublicAppleKey",
              "LessMeetPrivacyURL", "LessMeetTermsURL")


class AgentChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        for folder in ("scripts", "Resources", "bin", "binary"):
            (self.root / folder).mkdir()
        for name in ("build-app.sh", "configure-app.mjs"):
            shutil.copyfile(ROOT / "scripts" / name, self.root / "scripts" / name)
        for name in ("Info.plist", "LessMeet.entitlements"):
            shutil.copyfile(ROOT / "Resources" / name, self.root / "Resources" / name)
        for name in ("Clerk_ClerkKit.bundle", "RevenueCat_RevenueCat.bundle"):
            (self.root / "binary" / name).mkdir()
        (self.root / "binary/LessMeet").write_text("not an executable")
        self.log = self.root / "calls.jsonl"
        stub = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with open(os.environ["TEST_LOG"], "a") as log:
    log.write(json.dumps([Path(sys.argv[0]).name, *sys.argv[1:]]) + "\\n")
if Path(sys.argv[0]).name == "swift" and "--show-bin-path" in sys.argv:
    print(os.environ["TEST_BINARY"])
'''
        for tool in ("swift", "codesign"):
            path = self.root / "bin" / tool
            path.write_text(stub)
            path.chmod(0o755)
        self.env = {"PATH": str(self.root / "bin") + os.pathsep + os.environ["PATH"],
                    "TEST_LOG": str(self.log), "TEST_BINARY": str(self.root / "binary")}

    def run_build(self, mode, values=None, preflight=False):
        args = ["bash", "scripts/build-app.sh", mode]
        if preflight:
            args.append("--preflight")
        return subprocess.run(args, cwd=self.root, env={**self.env, **(values or {})},
                              capture_output=True, text=True)

    def configure(self, mode, values=None):
        return subprocess.run(["node", "scripts/configure-app.mjs", "Resources/Info.plist", mode],
                              cwd=self.root, env={**self.env, **(values or {})}, capture_output=True, text=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_offline_strips_stale_config_and_ignores_local_and_environment(self):
        # A directory fails if the implementation tries to read .env.local.
        (self.root / ".env.local").mkdir()
        path = self.root / "Resources/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info.update({key: "stale" for key in PROPERTIES})
        info["LessMeetPackagingMode"] = "dev"
        path.write_bytes(plistlib.dumps(info))
        result = self.run_build("offline-check", {key: "invalid" for key in
                                (*PUBLIC, "REVENUECAT_PUBLIC_APPLE_KEY", "LESSMEET_PRIVACY_URL", "LESSMEET_TERMS_URL")})
        self.assertEqual(result.returncode, 0, result.stderr)
        info = plistlib.loads((self.root / "dist/offline-check/LessMeet.app/Contents/Info.plist").read_bytes())
        self.assertEqual(info["LessMeetPackagingMode"], "offline-check")
        self.assertEqual(info["CFBundleIdentifier"], "com.lessmeet.app.offline-check")
        self.assertEqual(info["CFBundleDisplayName"], "LessMeet Offline Check")
        self.assertFalse(set(PROPERTIES + ("CFBundleURLTypes",)) & info.keys())
        swift = [call for call in self.calls() if call[0] == "swift"]
        self.assertEqual(len(swift), 2)
        for call in swift:
            self.assertIn("-DLESSMEET_OFFLINE_CHECK", call)
            self.assertIn("-Xswiftc", call)
            self.assertIn(str(self.root / "dist/offline-check/swift-build"), call)
        sign = next(call for call in self.calls() if "--sign" in call)
        self.assertEqual(sign[sign.index("--sign") + 1], "-")

    def test_auth_identity_fails_before_any_build_or_config(self):
        (self.root / ".env.local").mkdir()
        for value in (None, "", "-", " \t", " - "):
            for preflight in (False, True):
                with self.subTest(value=value, preflight=preflight):
                    values = {} if value is None else {"LESSMEET_SIGNING_IDENTITY": value}
                    result = self.run_build("auth-check", values, preflight)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("requires explicit", result.stderr)
                    self.assertEqual(self.calls(), [])
                    self.assertFalse((self.root / "dist").exists())

    def test_offline_does_not_use_an_inherited_signing_key(self):
        result = self.run_build("offline-check", {"LESSMEET_SIGNING_IDENTITY": "Operator private signing key"})
        self.assertEqual(result.returncode, 0, result.stderr)
        sign = next(call for call in self.calls() if "--sign" in call)
        self.assertEqual(sign[sign.index("--sign") + 1], "-")

    def test_auth_uses_only_explicit_public_values_and_preserves_identity(self):
        (self.root / ".env.local").mkdir()
        values = {**PUBLIC, "LESSMEET_SIGNING_IDENTITY": "Synthetic Identity",
                  "CLERK_SECRET_KEY": "must-not-be-copied"}
        result = self.run_build("auth-check", values)
        self.assertEqual(result.returncode, 0, result.stderr)
        info = plistlib.loads((self.root / "dist/auth-check/LessMeet.app/Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "com.lessmeet.app")
        self.assertEqual(info["CFBundleDisplayName"], "LessMeet")
        self.assertEqual(info["LessMeetPackagingMode"], "auth-check")
        self.assertIn("CFBundleURLTypes", info)
        self.assertNotIn("RevenueCatPublicAppleKey", info)
        self.assertNotIn("must-not-be-copied", str(info))
        sign = next(call for call in self.calls() if "--sign" in call)
        self.assertEqual(sign[sign.index("--sign") + 1], "Synthetic Identity")
        self.assertFalse(any("-DLESSMEET_OFFLINE_CHECK" in call for call in self.calls()))

    def test_auth_required_config_cannot_come_from_local_file(self):
        (self.root / ".env.local").write_text("\n".join(f"{key}={value}" for key, value in PUBLIC.items()))
        for missing in PUBLIC:
            values = {key: value for key, value in PUBLIC.items() if key != missing}
            result = self.run_build("auth-check", {**values, "LESSMEET_SIGNING_IDENTITY": "Synthetic"})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(missing, result.stderr)
            self.assertEqual(self.calls(), [])

    def test_auth_optional_values_validated_and_stale_values_removed(self):
        path = self.root / "Resources/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info.update({key: "stale" for key in PROPERTIES})
        path.write_bytes(plistlib.dumps(info))
        result = self.configure("auth-check", PUBLIC)
        self.assertEqual(result.returncode, 0, result.stderr)
        info = plistlib.loads(path.read_bytes())
        self.assertNotIn("RevenueCatPublicAppleKey", info)
        self.assertNotIn("LessMeetPrivacyURL", info)
        result = self.configure("auth-check", {**PUBLIC, "REVENUECAT_PUBLIC_APPLE_KEY": "secret"})
        self.assertNotEqual(result.returncode, 0)

    def test_preflight_does_not_build_or_sign(self):
        for mode, values in (("offline-check", {}), ("auth-check", {**PUBLIC, "LESSMEET_SIGNING_IDENTITY": "Synthetic"})):
            result = self.run_build(mode, values, True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.calls(), [])
            self.assertFalse((self.root / "dist").exists())

    def test_auth_sign_failure_has_no_fallback_or_published_replacement(self):
        sign = self.root / "bin/codesign"
        sign.write_text(sign.read_text() + "sys.exit(45)\n")
        app = self.root / "dist/auth-check/LessMeet.app"
        app.mkdir(parents=True)
        (app / "previous").write_text("keep existing artifact")
        result = self.run_build("auth-check", {**PUBLIC, "LESSMEET_SIGNING_IDENTITY": "Synthetic"})
        self.assertEqual(result.returncode, 45)
        calls = [call for call in self.calls() if call[0] == "codesign"]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][calls[0].index("--sign") + 1], "Synthetic")
        self.assertEqual((app / "previous").read_text(), "keep existing artifact")
        self.assertFalse((app / "Contents").exists())

    def test_auth_accepts_optional_public_rc_and_legal(self):
        result = self.configure("auth-check", {**PUBLIC, "REVENUECAT_PUBLIC_APPLE_KEY": "appl_synthetic",
                                               "LESSMEET_PRIVACY_URL": "https://example.com/privacy",
                                               "LESSMEET_TERMS_URL": "https://example.com/terms"})
        self.assertEqual(result.returncode, 0, result.stderr)
        info = plistlib.loads((self.root / "Resources/Info.plist").read_bytes())
        self.assertEqual(info["RevenueCatPublicAppleKey"], "appl_synthetic")
        self.assertEqual(info["LessMeetTermsURL"], "https://example.com/terms")

    def test_dev_remains_compatible_and_warns_for_adhoc_auth(self):
        (self.root / ".env.local").write_text("\n".join(f"{key}={value}" for key, value in PUBLIC.items()))
        result = self.run_build("dev")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ad-hoc signing with auth configuration", result.stderr)
        self.assertTrue((self.root / "dist/LessMeet.app").exists())


if __name__ == "__main__":
    unittest.main()
