"""Offline policy and orchestration tests. All credentials/configuration are synthetic."""
import datetime as dt
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("signing", ROOT / "scripts/packaging-signing.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
NOW = dt.datetime(2026, 9, 23, tzinfo=dt.timezone.utc)
DER = b"synthetic-certificate-member"
FINGERPRINT = hashlib.sha1(DER).hexdigest().upper()
DEVICE = "SYNTHETIC-MAC-UDID"
PUBLIC = {
    "CLERK_PUBLISHABLE_KEY": "pk_test_c3ludGhldGlj",
    "CONVEX_SITE_URL": "https://zany-octopus-315.convex.site",
    "REVENUECAT_PUBLIC_APPLE_KEY": "appl_synthetic",
    "LESSMEET_PRIVACY_URL": "https://example.com/privacy",
    "LESSMEET_TERMS_URL": "https://example.com/terms",
}
STORE_PUBLIC = {**PUBLIC, "CLERK_PUBLISHABLE_KEY": "pk_live_c3ludGhldGlj",
                "CONVEX_SITE_URL": "https://synthetic-production.convex.site"}


def environment():
    # Do not inherit operator configuration or credentials.
    return {"PATH": os.environ["PATH"], "LC_ALL": "C", "PYTHONDONTWRITEBYTECODE": "1"}


def profile(mode="sandbox-dev"):
    value = {
        "Platform": ["OSX"], "TeamIdentifier": [signing.TEAM],
        "ApplicationIdentifierPrefix": ["OLDPREFIX1"],
        "CreationDate": NOW - dt.timedelta(days=1),
        "ExpirationDate": NOW + dt.timedelta(days=1),
        "DeveloperCertificates": [DER],
        "Entitlements": {"com.apple.application-identifier": "OLDPREFIX1.com.lessmeet.app",
                         "com.apple.developer.team-identifier": signing.TEAM,
                         "com.apple.security.app-sandbox": True,
                         "get-task-allow": mode == "sandbox-dev",
                         "keychain-access-groups": ["OLDPREFIX1.*"]},
    }
    if mode == "sandbox-dev":
        value["ProvisionedDevices"] = [DEVICE]
    return value


def cert(mode="sandbox-dev"):
    return {"name": ("Apple Development:" if mode == "sandbox-dev" else "Apple Distribution:") + " Synthetic",
            "team": signing.TEAM, "valid": True}


class SigningPolicyTests(unittest.TestCase):
    def check(self, value=None, mode="sandbox-dev", **kwargs):
        return signing.validate(value if value is not None else profile(mode), mode,
                                kwargs.get("fingerprint", FINGERPRINT), kwargs.get("certificate", cert(mode)),
                                kwargs.get("device", DEVICE), NOW)

    def test_distinct_application_prefix_and_minimal_generated_entitlements(self):
        result = self.check()
        self.assertEqual(result, {"com.apple.application-identifier": "OLDPREFIX1.com.lessmeet.app",
                                  "com.apple.developer.team-identifier": signing.TEAM})
        self.assertNotIn("keychain-access-groups", result)
        self.assertNotIn("get-task-allow", result)
        self.check(mode="store")

    def test_macos_unrestricted_entitlements_may_be_absent(self):
        for mode in ["sandbox-dev", "store"]:
            data = profile(mode)
            del data["Entitlements"]["com.apple.security.app-sandbox"]
            del data["Entitlements"]["get-task-allow"]
            self.check(data, mode)

    def test_invalid_profile_matrix(self):
        changes = [
            ("Platform", ["iOS"]), ("Platform", ["OSX", "iOS"]),
            ("ExpirationDate", NOW), ("ExpirationDate", "future"),
            ("CreationDate", NOW + dt.timedelta(days=1)),
            ("TeamIdentifier", ["WRONGTEAM"]),
            ("ApplicationIdentifierPrefix", ["WRONGPREFIX"]),
            ("ApplicationIdentifierPrefix", []), ("DeveloperCertificates", [b"other"]),
            ("ProvisionedDevices", ["OTHER-MAC"]), ("ProvisionedDevices", []),
            ("ProvisionsAllDevices", True),
        ]
        for key, value in changes:
            with self.subTest(key=key, value=value):
                data = profile()
                data[key] = value
                with self.assertRaises(signing.Invalid):
                    self.check(data)

    def test_invalid_entitlement_matrix(self):
        for key, value in [
            ("com.apple.application-identifier", "OLDPREFIX1.*"),
            ("com.apple.application-identifier", "OLDPREFIX1.com.other.app"),
            ("com.apple.developer.team-identifier", "OTHERTEAM"),
            ("com.apple.security.app-sandbox", False),
            ("get-task-allow", False), ("get-task-allow", "true"),
            ("application-identifier", "OTHERPREFIX.com.lessmeet.app"),
        ]:
            with self.subTest(key=key, value=value):
                data = profile()
                data["Entitlements"][key] = value
                with self.assertRaises(signing.Invalid):
                    self.check(data)

    def test_invalid_certificates_and_device(self):
        for changes in [{"valid": False}, {"team": "OTHERTEAM"},
                        {"name": "Developer ID Application: Synthetic"}, {"name": "Apple Distribution: Synthetic"}]:
            with self.subTest(changes=changes), self.assertRaises(signing.Invalid):
                self.check(certificate={**cert(), **changes})
        with self.assertRaises(signing.Invalid):
            self.check(device=None)
        with self.assertRaises(signing.Invalid):
            self.check(fingerprint="0" * 40)

    def test_store_rejects_debug_and_non_store_profiles(self):
        for key in ["get-task-allow", "com.apple.security.get-task-allow"]:
            data = profile("store")
            data["Entitlements"][key] = True
            with self.assertRaises(signing.Invalid):
                self.check(data, "store")
        for key, value in [("ProvisionedDevices", []), ("ProvisionsAllDevices", True)]:
            data = profile("store")
            data[key] = value
            with self.assertRaises(signing.Invalid):
                self.check(data, "store")
        with self.assertRaises(signing.Invalid):
            self.check(mode="store", certificate=cert())
        for name in ["Apple Distribution: Synthetic", "Mac App Distribution: Synthetic", "3rd Party Mac Developer Application: Synthetic"]:
            self.check(mode="store", certificate={**cert("store"), "name": name})

    def test_identifier_alias_and_missing_profile_fields(self):
        data = profile()
        ent = data["Entitlements"]
        ent["application-identifier"] = ent.pop("com.apple.application-identifier")
        self.assertEqual(self.check(data)["application-identifier"], "OLDPREFIX1.com.lessmeet.app")
        for key in ["Platform", "CreationDate", "ExpirationDate", "Entitlements", "TeamIdentifier",
                    "ApplicationIdentifierPrefix", "DeveloperCertificates", "ProvisionedDevices"]:
            data = profile()
            del data[key]
            with self.subTest(key=key), self.assertRaises(signing.Invalid):
                self.check(data)

    def test_identity_selection_requires_unambiguous_exact_match(self):
        output = f'1) {FINGERPRINT} "Apple Development: Synthetic"\n'
        self.assertEqual(signing.select_identity(output, FINGERPRINT.lower()), FINGERPRINT)
        self.assertEqual(signing.select_identity(output, "Apple Development: Synthetic"), FINGERPRINT)
        for request in ["-", "", "Synthetic", "Developer ID"]:
            with self.assertRaises(signing.Invalid):
                signing.select_identity(output, request)
        with self.assertRaises(signing.Invalid):
            signing.select_identity(output + '2) ' + '0' * 40 + ' "Apple Development: Synthetic"', "Apple Development: Synthetic")
        with self.assertRaises(signing.Invalid):
            signing.select_identity(f'1) {FINGERPRINT} "Developer ID Application: Synthetic"', FINGERPRINT)

    def test_main_snapshots_profile_and_omits_broad_entitlements(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "synthetic.provisionprofile"
            source.write_bytes(b"synthetic CMS bytes")
            output = Path(folder) / "validated"
            data = profile()
            # Keep this CLI-boundary fixture valid independently of the calendar.
            data["CreationDate"] = dt.datetime.now() - dt.timedelta(days=1)
            data["ExpirationDate"] = dt.datetime.now() + dt.timedelta(days=1)
            def fake_run(args, **kwargs):
                if args[1] == "cms":
                    self.assertEqual(Path(args[-1]).read_bytes(), b"synthetic CMS bytes")
                    source.write_bytes(b"changed after snapshot")
                    return plistlib.dumps(data)
                if args[1] == "find-identity":
                    return f'1) {FINGERPRINT} "Apple Development: Synthetic"'.encode()
                return json.dumps({"SPHardwareDataType": [{"provisioning_UDID": DEVICE, "platform_UUID": "NOT-THE-UDID"}]}).encode()
            with patch.dict(os.environ, {"LESSMEET_SIGNING_IDENTITY": FINGERPRINT,
                                         "LESSMEET_PROVISIONING_PROFILE": str(source)}, clear=True), \
                 patch.object(sys, "argv", ["packaging-signing.py", "sandbox-dev", "--output", str(output)]), \
                 patch.object(signing, "run", side_effect=fake_run), \
                 patch.object(signing, "certificate_metadata", return_value=cert()), \
                 patch("sys.stdout", new_callable=io.StringIO) as log:
                signing.main()
            self.assertEqual((output / "embedded.provisionprofile").read_bytes(), b"synthetic CMS bytes")
            ent = plistlib.loads((output / "entitlements.plist").read_bytes())
            self.assertEqual(len(ent), 5)
            self.assertNotIn("keychain-access-groups", ent)
            self.assertNotIn(FINGERPRINT, log.getvalue())

    def test_openssl_metadata_parser_without_certificate_creation(self):
        metadata = ("subject=\n    CN = Apple Development: Synthetic\n    OU = " + signing.TEAM +
                    "\nnotBefore=Jan  1 00:00:00 2020 GMT\nnotAfter=Jan  1 00:00:00 2099 GMT\n").encode()
        with patch.object(signing, "run", return_value=metadata):
            self.assertEqual(signing.certificate_metadata(DER), cert())


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.plist = self.folder / "Info.plist"
        shutil.copy(ROOT / "Resources/Info.plist", self.plist)

    def configure(self, values, mode="sandbox-dev", check=False):
        return subprocess.run(["node", str(ROOT / "scripts/configure-app.mjs"),
                               "--check" if check else str(self.plist), mode], cwd=self.folder,
                              env={**environment(), **values}, capture_output=True, text=True)

    def test_signed_all_public_fields_and_callback(self):
        self.assertEqual(self.configure(PUBLIC).returncode, 0)
        info = plistlib.loads(self.plist.read_bytes())
        self.assertEqual(info["ConvexSiteURL"], PUBLIC["CONVEX_SITE_URL"])
        self.assertEqual(info["CFBundleURLTypes"][0]["CFBundleURLSchemes"], ["com.lessmeet.app"])

    def test_every_missing_field_fails_without_partial_write(self):
        original = self.plist.read_bytes()
        for key in PUBLIC:
            for mode in ["sandbox-dev", "store"]:
                if mode == "sandbox-dev" and key in ["LESSMEET_PRIVACY_URL", "LESSMEET_TERMS_URL"]:
                    continue
                result = self.configure({k: v for k, v in PUBLIC.items() if k != key}, mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(key, result.stderr)
                self.assertEqual(self.plist.read_bytes(), original)

    def test_internal_build_without_unpublished_legal_links(self):
        values = {k: v for k, v in PUBLIC.items() if k not in ["LESSMEET_PRIVACY_URL", "LESSMEET_TERMS_URL"]}
        self.assertEqual(self.configure(values).returncode, 0)
        info = plistlib.loads(self.plist.read_bytes())
        self.assertEqual(info["LessMeetPackagingMode"], "sandbox-dev")
        self.assertNotIn("LessMeetPrivacyURL", info)
        self.assertNotIn("LessMeetTermsURL", info)

    def test_invalid_inputs_do_not_leak_values(self):
        cases = [("CLERK_PUBLISHABLE_KEY", "sk_test_DO_NOT_PRINT"),
                 ("REVENUECAT_PUBLIC_APPLE_KEY", "sk_DO_NOT_PRINT"),
                 ("CONVEX_SITE_URL", "https://wrong.convex.site"),
                 ("CONVEX_SITE_URL", "http://DO_NOT_PRINT.invalid"),
                 ("LESSMEET_PRIVACY_URL", "not-a-url-DO_NOT_PRINT"),
                 ("LESSMEET_TERMS_URL", "https://DO_NOT_PRINT:password@example.com"),
                 ("LESSMEET_TERMS_URL", "https://example.com/DO_NOT_PRINT'bad")]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                result = self.configure({**PUBLIC, key: value})
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(value, result.stdout + result.stderr)
                self.assertNotIn("DO_NOT_PRINT", result.stdout + result.stderr)

    def test_dev_optional_config_and_local_env_compatibility(self):
        self.assertEqual(self.configure({}, "dev").returncode, 0)
        shutil.copy(ROOT / "Resources/Info.plist", self.plist)
        (self.folder / ".env.local").write_text("CLERK_PUBLISHABLE_KEY=pk_test_bG9jYWw=\n")
        self.assertEqual(self.configure({}, "dev").returncode, 0)
        self.assertEqual(plistlib.loads(self.plist.read_bytes())["ClerkPublishableKey"], "pk_test_bG9jYWw=")

    def test_signed_ignores_local_env_and_check_has_no_writes(self):
        (self.folder / ".env.local").write_text("\n".join(f"{k}={v}" for k, v in PUBLIC.items()))
        self.assertNotEqual(self.configure({}).returncode, 0)
        original = self.plist.read_bytes()
        self.assertEqual(self.configure(PUBLIC, check=True).returncode, 0)
        self.assertEqual(self.plist.read_bytes(), original)

    def test_dev_exported_public_value_overrides_local_config(self):
        (self.folder / ".env.local").write_text("CLERK_PUBLISHABLE_KEY=pk_test_bG9jYWw=\n")
        self.assertEqual(self.configure(PUBLIC, "dev").returncode, 0)
        self.assertEqual(plistlib.loads(self.plist.read_bytes())["ClerkPublishableKey"], PUBLIC["CLERK_PUBLISHABLE_KEY"])


class BuildFlowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        for name in ["scripts", "Resources", "fake-bin", "binary", "dist/LessMeet.app", "recordings"]:
            (self.folder / name).mkdir(parents=True)
        for name in ["build-app.sh", "configure-app.mjs", "packaging-signing.py", "store-package.py"]:
            shutil.copy(ROOT / "scripts" / name, self.folder / "scripts" / name)
        for name in ["Info.plist", "LessMeet.entitlements", "LessMeet.sandbox.entitlements"]:
            shutil.copy(ROOT / "Resources" / name, self.folder / "Resources" / name)
        (self.folder / "dist/LessMeet.app/sentinel").write_text("existing dev app")
        (self.folder / "recordings/sentinel").write_text("existing recordings")
        (self.folder / "binary/LessMeet").write_text("synthetic binary")
        for name in ["Clerk_ClerkKit.bundle", "RevenueCat_RevenueCat.bundle"]:
            (self.folder / "binary" / name).mkdir()
            (self.folder / "binary" / name / "resource").write_text("SDK resource")
        self.stub("swift", '#!/bin/bash\nprintf "swift\\n" >> invoked\nif [[ "$*" == *--show-bin-path* ]]; then printf "%s/binary\\n" "$PWD"; fi\n')
        self.stub("codesign", '''#!/bin/bash
printf 'codesign %s\n' "$*" >> invoked
[[ "$*" != *--deep* ]] || exit 19
app="${@: -1}"
[[ -f "$app/Contents/Resources/Clerk_ClerkKit.bundle/resource" ]] || exit 20
[[ -f "$app/Contents/Resources/RevenueCat_RevenueCat.bundle/resource" ]] || exit 21
if [[ "$app" == */sandbox-dev/* || "$app" == */store/* ]]; then
  [[ -f "$app/Contents/embedded.provisionprofile" ]] || exit 22
fi
''')
        self.env = {**environment(), "PATH": str(self.folder / "fake-bin") + ":" + os.environ["PATH"]}

    def stub(self, name, body):
        path = self.folder / "fake-bin" / name
        path.write_text(body)
        path.chmod(0o755)

    def build(self, *args, values=None):
        if args and args[0] == "store" and values is PUBLIC:
            values = STORE_PUBLIC
        return subprocess.run(["bash", "scripts/build-app.sh", *args], cwd=self.folder,
                              env={**self.env, **(values or {})}, capture_output=True, text=True)

    def fake_signing_boundary(self):
        # Orchestration only: real signing policy is tested separately above.
        self.stub("python3", '''#!/bin/bash
[[ "$1" != scripts/store-package.py ]] || exit 0
[[ "$1" == scripts/packaging-signing.py ]] || exit 30
if [[ "${3:-}" == --output ]]; then
  mkdir "$4"
  cp Resources/LessMeet.sandbox.entitlements "$4/entitlements.plist"
  printf synthetic-profile > "$4/embedded.provisionprofile"
  printf synthetic-fingerprint > "$4/identity.txt"
fi
''')

    def test_default_dev_preserves_original_entitlements_and_resources(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        log = (self.folder / "invoked").read_text()
        self.assertIn("--sign - --options runtime --entitlements Resources/LessMeet.entitlements", log)
        self.assertIn("--verify --strict", log)
        self.assertFalse((self.folder / "dist/LessMeet.app/Contents/embedded.provisionprofile").exists())
        self.assertEqual(len(list((self.folder / "dist").glob("build.*/Previous-LessMeet.app/sentinel"))), 1)
        self.assertEqual((self.folder / "recordings/sentinel").read_text(), "existing recordings")

    def test_signed_modes_isolate_outputs_embed_before_sign_and_retain_old_artifact(self):
        self.fake_signing_boundary()
        for mode in ["sandbox-dev", "store"]:
            result = self.build(mode, values=PUBLIC)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((self.folder / "dist" / mode / "LessMeet.app/Contents/embedded.provisionprofile").exists())
            self.assertEqual(self.build(mode, values=PUBLIC).returncode, 0)
            self.assertEqual(len(list((self.folder / "dist" / mode).glob("build.*/Previous-LessMeet.app"))), 1)
        self.assertIn(".app only", result.stdout)
        self.assertEqual((self.folder / "dist/LessMeet.app/sentinel").read_text(), "existing dev app")
        self.assertEqual((self.folder / "recordings/sentinel").read_text(), "existing recordings")
        self.assertNotIn("--deep", (self.folder / "invoked").read_text())

    def test_failed_sign_or_verification_preserves_published_artifacts(self):
        self.fake_signing_boundary()
        for failure in ["sign", "verify"]:
            output = self.folder / "dist/store/LessMeet.app"
            output.mkdir(parents=True, exist_ok=True)
            (output / "sentinel").write_text("existing store app")
            if failure == "sign":
                self.stub("codesign", "#!/bin/bash\nexit 45\n")
            else:
                self.stub("codesign", '#!/bin/bash\n[[ "$1" != --verify ]]\n')
            self.assertNotEqual(self.build("store", values=PUBLIC).returncode, 0)
            self.assertEqual((output / "sentinel").read_text(), "existing store app")
            self.assertEqual((self.folder / "dist/LessMeet.app/sentinel").read_text(), "existing dev app")
            self.assertEqual((self.folder / "recordings/sentinel").read_text(), "existing recordings")

    def test_dev_explicit_signing_identity_is_retained(self):
        result = self.build(values={"LESSMEET_SIGNING_IDENTITY": "Synthetic Dev Identity"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--sign Synthetic Dev Identity", (self.folder / "invoked").read_text())

    def test_preflight_never_builds_signs_or_creates_artifacts(self):
        self.fake_signing_boundary()
        for mode in ["dev", "sandbox-dev", "store"]:
            result = self.build(mode, "--preflight", values=PUBLIC)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.folder / "invoked").exists())
        self.assertFalse((self.folder / "dist/sandbox-dev").exists())

    def test_missing_or_ad_hoc_identity_rejected_before_build(self):
        for identity in ["", "-"]:
            result = self.build("sandbox-dev", "--preflight", values={**PUBLIC, "LESSMEET_SIGNING_IDENTITY": identity})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Explicit signing identity", result.stderr)
        self.assertFalse((self.folder / "invoked").exists())

    def test_missing_profile_rejected_before_build(self):
        result = self.build("sandbox-dev", "--preflight", values={**PUBLIC, "LESSMEET_SIGNING_IDENTITY": "Apple Development: Synthetic"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Explicit provisioning profile", result.stderr)
        self.assertFalse((self.folder / "invoked").exists())

    def test_bad_arguments_and_missing_config_fail_before_build(self):
        for args in [("invalid",), ("store", "unexpected"), ("dev", "build", "extra"), ("sandbox-dev",)]:
            self.assertNotEqual(self.build(*args).returncode, 0)
        self.assertFalse((self.folder / "invoked").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
