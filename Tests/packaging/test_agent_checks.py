"""Offline packaging tests. Swift and signing calls use inert test doubles."""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from local_packaging_fixtures import BUNDLES, NOTICES, METALLIB, install, inventory


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
        self.log = self.root / "calls.jsonl"
        self.env = install(self.root, "bin")

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

    def test_local_and_offline_ignore_stale_revenuecat_bundle(self):
        stale = self.root / "binary/RevenueCat_RevenueCat.bundle"
        stale.mkdir()
        (stale / "old-resource").write_bytes(b"retired SDK cache")
        for mode in ("local", "offline-check"):
            with self.subTest(mode=mode):
                result = self.run_build(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                resources = self.root / "dist" / mode / "LessMeet.app/Contents/Resources"
                self.assertFalse((resources / "RevenueCat_RevenueCat.bundle").exists())
                for bundle in BUNDLES:
                    self.assertTrue((resources / bundle).is_dir())
        self.assertTrue((stale / "old-resource").is_file())

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

    def test_chat_ui_check_is_isolated_and_ignores_service_and_signing_inputs(self):
        (self.root / ".env.local").mkdir()
        path = self.root / "Resources/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info.update({key: "stale" for key in PROPERTIES})
        path.write_bytes(plistlib.dumps(info))
        result = self.run_build("chat-ui-check", {
            **{key: "invalid" for key in PUBLIC},
            "LESSMEET_SIGNING_IDENTITY": "Do not unlock this key"})
        self.assertEqual(result.returncode, 0, result.stderr)
        info = plistlib.loads((self.root / "dist/chat-ui-check/LessMeet.app/Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "com.lessmeet.app.chat-ui-check")
        self.assertEqual(info["LessMeetPackagingMode"], "chat-ui-check")
        self.assertFalse(set(PROPERTIES + ("CFBundleURLTypes",)) & info.keys())
        for call in self.calls():
            if call[0] == "swift":
                self.assertIn("-DLESSMEET_CHAT_UI_CHECK", call)
                self.assertNotIn("-DLESSMEET_OFFLINE_CHECK", call)
            if "--sign" in call:
                self.assertEqual(call[call.index("--sign") + 1], "-")

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
        for mode, values in (("local", {}), ("offline-check", {}), ("auth-check", {**PUBLIC, "LESSMEET_SIGNING_IDENTITY": "Synthetic"})):
            result = self.run_build(mode, values, True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.calls(), [])
            self.assertFalse((self.root / "dist").exists())

    def test_auth_sign_failure_has_no_fallback_or_published_replacement(self):
        self.env["TEST_SIGN_EXIT"] = "45"
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

    def test_local_strips_stale_services_and_callback_ignores_invalid_inputs(self):
        (self.root / ".env.local").mkdir()  # Reading this as a file must fail.
        path = self.root / "Resources/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info.update({key: "stale" for key in PROPERTIES})
        info["CFBundleURLTypes"] = [{"CFBundleURLSchemes": ["stale-callback"]}]
        info["LessMeetPackagingMode"] = "store"
        path.write_bytes(plistlib.dumps(info))
        result = self.run_build("local", {key: "invalid-secret-not-to-copy" for key in
                                (*PUBLIC, "REVENUECAT_PUBLIC_APPLE_KEY", "LESSMEET_PRIVACY_URL", "LESSMEET_TERMS_URL")})
        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.root / "dist/local/LessMeet.app"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "com.lessmeet.app.local")
        self.assertEqual(info["LessMeetPackagingMode"], "local")
        self.assertFalse(set(PROPERTIES + ("CFBundleURLTypes",)) & info.keys())
        self.assertNotIn("invalid-secret", str(info) + result.stdout + result.stderr)
        self.assertEqual((app / "Contents/MacOS/mlx.metallib").read_bytes(), METALLIB)
        self.assertEqual((app / "Contents/Resources/mlx.metallib").read_bytes(), METALLIB)
        self.assertTrue((app / "Contents/MacOS/mlx.metallib").is_symlink())
        log = (self.root / "invoked").read_text().splitlines()
        shader = next(line for line in log if line.startswith("shader "))
        staged = Path(shader.removeprefix("shader "))
        self.assertEqual(staged.name, "mlx-build")
        self.assertTrue(staged.parent.name.startswith("build."))
        self.assertEqual(staged.parent.parent, app.parent)
        self.assertLess(log.index(shader), next(i for i, line in enumerate(log) if line.startswith("codesign ")))
        self.assertEqual(set(inventory(app / "Contents/Resources/ModelLicenses")), set(NOTICES))
        self.assertEqual(inventory(app / "Contents/Resources/ModelLicenses"), inventory(ROOT / "Resources/ModelLicenses"))
        for bundle in BUNDLES:
            self.assertEqual(inventory(app / "Contents/Resources" / bundle), inventory(self.root / "binary" / bundle))
        for call in self.calls():
            if call[0] == "swift":
                self.assertIn("--disable-keychain", call)
                self.assertIn("--disable-netrc", call)
                self.assertEqual(call[call.index("--scratch-path") + 1], str(self.root / "dist/local/swift-build"))
                self.assertNotIn("-DLESSMEET_OFFLINE_CHECK", call)

    def test_missing_metal_stops_before_build_sign_or_replacement(self):
        app = self.root / "dist/local/LessMeet.app"
        app.mkdir(parents=True)
        (app / "previous").write_text("keep")
        result = self.run_build("local", {"TEST_METAL_EXIT": "46"})
        self.assertEqual(result.returncode, 46, result.stderr)
        self.assertEqual(self.calls(), [["xcrun", "-sdk", "macosx", "metal", "--version"]])
        self.assertEqual(inventory(app), {"previous": b"keep"})
        self.assertEqual(list(app.parent.glob("build.*")), [])

    def assert_stops_before_sign(self, values=None):
        app = self.root / "dist/local/LessMeet.app"
        app.mkdir(parents=True, exist_ok=True)
        (app / "previous").write_text("keep")
        previous_count = len(self.calls())
        result = self.run_build("local", values)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        current = self.calls()[previous_count:]
        self.assertEqual(sum(call[0] == "swift" for call in current), 2, result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(any(call[0] == "codesign" for call in self.calls()))
        self.assertEqual(inventory(app), {"previous": b"keep"})

    def test_each_missing_bundle_stops_signing(self):
        for name in BUNDLES:
            with self.subTest(bundle=name):
                source = self.root / "binary" / name
                moved = source.with_suffix(".hidden")
                source.rename(moved)
                try:
                    self.assert_stops_before_sign()
                finally:
                    moved.rename(source)

    def test_each_missing_notice_stops_signing(self):
        for name in NOTICES:
            with self.subTest(notice=name):
                source = self.root / "Resources/ModelLicenses" / name
                original = source.read_bytes()
                source.unlink()
                try:
                    self.assert_stops_before_sign()
                finally:
                    source.write_bytes(original)

    def test_each_mismatched_pin_stops_signing(self):
        path = self.root / "Package.resolved"
        original = path.read_text()
        for dependency in ("speech-swift", "mlx-swift"):
            with self.subTest(dependency=dependency):
                data = json.loads(original)
                next(pin for pin in data["pins"] if pin["identity"] == dependency)["state"]["revision"] = "0" * 40
                path.write_text(json.dumps(data))
                self.assert_stops_before_sign()
        path.write_text(original)

    def test_each_dirty_checkout_stops_signing(self):
        for dependency in ("speech-swift", "mlx-swift"):
            for tracked in (True, False):
                with self.subTest(dependency=dependency, tracked=tracked):
                    path = self.root / "fixture-checkouts" / dependency / ("source" if tracked else "untracked")
                    path.write_text("dirty\n")
                    self.assert_stops_before_sign()
                    if tracked:
                        path.write_text("synthetic source\n")
                    else:
                        path.unlink()
                    # Each attempt gets fresh checkout bytes, without stale untracked files.
                    shutil.rmtree(self.root / "dist/local/swift-build/checkouts")

    def test_shader_failure_stops_signing(self):
        self.assert_stops_before_sign({"TEST_SHADER_FAIL": "1"})

    def test_empty_shader_output_stops_signing(self):
        self.assert_stops_before_sign({"TEST_SHADER_EMPTY": "1"})

    def test_local_sign_failure_retains_previous_app(self):
        app = self.root / "dist/local/LessMeet.app"
        app.mkdir(parents=True)
        (app / "previous").write_text("keep")
        result = self.run_build("local", {"TEST_SIGN_EXIT": "45"})
        self.assertEqual(result.returncode, 45, result.stderr)
        self.assertEqual(inventory(app), {"previous": b"keep"})
        signing = [call for call in self.calls() if call[0] == "codesign"]
        self.assertEqual(len(signing), 1)
        self.assertIn("--sign", signing[0])


if __name__ == "__main__":
    unittest.main()
