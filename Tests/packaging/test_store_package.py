"""Synthetic-only store tests; all Apple identity/signing/icon tool calls mocked."""
import hashlib
import importlib.util
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

from test_packaging import ROOT, PUBLIC, STORE_PUBLIC, environment, profile, cert, DER, FINGERPRINT

spec = importlib.util.spec_from_file_location("store", ROOT / "scripts/store-package.py")
store = importlib.util.module_from_spec(spec)
spec.loader.exec_module(store)
ICON = b"icns\x00\x00\x00\x08"  # Deliberately not artwork; conversion is mocked.
INSTALLER = "3rd Party Mac Developer Installer: Synthetic (63M98WD275)"


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.icon = self.folder / "approved.icns"
        self.icon.write_bytes(ICON)
        self.approval = {
            "schema": 1, "bundle": store.signing.BUNDLE, "team": store.signing.TEAM,
            "version": "1.2.3", "build": "42", "public_configuration": STORE_PUBLIC,
            "icon_sha256": store.digest(ICON), "approved_by": "SYNTHETIC ONLY",
            "production_backend_evidence": "synthetic offline assertion, not real evidence",
            "production_auth_billing_evidence": "synthetic", "published_legal_evidence": "synthetic",
            "approved_icon_evidence": "synthetic; no approved artwork exists",
        }
        self.approval_path = self.folder / "approval.json"
        self.write_approval()
        self.env = {**environment(), **STORE_PUBLIC, "LESSMEET_VERSION": "1.2.3", "LESSMEET_BUILD": "42",
                    "LESSMEET_STORE_APPROVAL": str(self.approval_path), "LESSMEET_ICON_ICNS": str(self.icon)}
        self.values = ("1.2.3", "42", STORE_PUBLIC, ICON, self.approval)
        self.app = self.folder / "LessMeet.app"
        (self.app / "Contents/Resources").mkdir(parents=True)
        (self.app / "Contents/MacOS").mkdir()
        (self.app / "Contents/MacOS/LessMeet").write_bytes(b"synthetic-not-executable")
        for name in ["Clerk_ClerkKit.bundle", "RevenueCat_RevenueCat.bundle"]:
            (self.app / "Contents/Resources" / name).mkdir()
        self.info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
        self.info.update({prop: STORE_PUBLIC[key] for key, prop in store.PUBLIC.items()})
        self.info["LessMeetPackagingMode"] = "store"
        self.info_path = self.app / "Contents/Info.plist"
        self.info_path.write_bytes(plistlib.dumps(self.info))
        store.stamp(self.app, self.values)
        self.calls = []

    def write_approval(self):
        self.approval_path.write_text(json.dumps(self.approval))

    def fake_run(self, args):
        self.calls.append([str(a) for a in args])
        if args[0] == "node":
            return store_run(args)  # Real public validation only; environment cleared by test.
        if args[0] == "/usr/bin/iconutil":
            target = Path(args[4])
            target.mkdir()
            for size in (16, 32, 128, 256, 512):
                for scale in (1, 2):
                    (target / ("icon_%dx%d%s.png" % (size, size, "@2x" if scale == 2 else ""))).write_bytes(b"synthetic")
            return b""
        if args[0] == "/usr/bin/sips":
            name = Path(args[-1]).name
            size = int(name.split("_")[1].split("x")[0]) * (2 if "@2x" in name else 1)
            return ("pixelWidth: %d\npixelHeight: %d\n" % (size, size)).encode()
        if args[0] == "/usr/bin/security" and args[1] == "find-identity":
            return ('1) ' + FINGERPRINT + ' "' + INSTALLER + '"').encode()
        if args[0] == "/usr/bin/productbuild":
            Path(args[-1]).write_bytes(b"synthetic pkg, not an Apple installer")
            return b""
        if args[0] == "/usr/sbin/pkgutil":
            return ("Status: signed by a certificate trusted by macOS\n  1. " + INSTALLER + "\n").encode()
        raise AssertionError("Unexpected command: " + str(args))

    def test_public_inputs_without_signing_access(self):
        with patch.dict(os.environ, self.env, clear=True), patch.object(store, "run", side_effect=self.fake_run):
            self.assertEqual(store.inputs(), self.values)
        self.assertEqual({c[0] for c in self.calls}, {"node", "/usr/bin/iconutil", "/usr/bin/sips"})

    def test_missing_and_invalid_release_inputs(self):
        cases = [(k, "") for k in ("LESSMEET_VERSION", "LESSMEET_BUILD", "LESSMEET_STORE_APPROVAL", "LESSMEET_ICON_ICNS")]
        cases += [("LESSMEET_VERSION", v) for v in ("1", "1.2", "1.2.3-beta", "1.2.3.4")]
        cases += [("LESSMEET_BUILD", v) for v in ("0", "01", "1.2.3.4", "1b2", "10000", "1.100")]
        for key, value in cases:
            with self.subTest(key=key, value=value), patch.dict(os.environ, {**self.env, key: value}, clear=True), \
                    patch.object(store, "run", side_effect=self.fake_run), self.assertRaises(store.Invalid):
                store.inputs()

    def test_approval_mismatches_missing_evidence_and_icon_gate(self):
        for key, value in [("schema", 2), ("bundle", "wrong"), ("team", "wrong"), ("version", "9.0.0"),
                           ("build", "43"), ("public_configuration", PUBLIC), ("icon_sha256", "0" * 64),
                           ("approved_by", ""), ("production_backend_evidence", ""),
                           ("production_auth_billing_evidence", ""), ("published_legal_evidence", ""),
                           ("approved_icon_evidence", "")]:
            modified = {**self.approval, key: value}
            self.approval_path.write_text(json.dumps(modified))
            with self.subTest(key=key), patch.dict(os.environ, self.env, clear=True), \
                    patch.object(store, "run", side_effect=self.fake_run), self.assertRaises(store.Invalid):
                store.inputs()

    def test_store_rejects_known_dev_and_test_clerk_even_if_attested(self):
        for key in ("CLERK_PUBLISHABLE_KEY", "CONVEX_SITE_URL"):
            values = {**STORE_PUBLIC, key: PUBLIC[key]}
            self.approval["public_configuration"] = values
            self.write_approval()
            with patch.dict(os.environ, {**self.env, **values}, clear=True), \
                    patch.object(store, "run", side_effect=self.fake_run), self.assertRaises(store.Invalid):
                store.inputs()

    def test_url_shape_without_approval_never_passes(self):
        with patch.dict(os.environ, {**self.env, "LESSMEET_STORE_APPROVAL": ""}, clear=True), \
                patch.object(store, "run") as command, self.assertRaises(store.Invalid):
            store.inputs()
        command.assert_not_called()

    def test_icon_missing_representation_and_dimensions_fail(self):
        def missing(args):
            result = self.fake_run(args)
            if args[0] == "/usr/bin/iconutil":
                (Path(args[4]) / "icon_512x512@2x.png").unlink()
            return result
        def wrong(args):
            return b"pixelWidth: 5\npixelHeight: 5\n" if args[0] == "/usr/bin/sips" else self.fake_run(args)
        for fake in (missing, wrong):
            with patch.object(store, "run", side_effect=fake), self.assertRaises(store.Invalid):
                store.validate_icon(ICON)

    def test_release_identity_template(self):
        info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleName"], "LessMeet")
        self.assertEqual(info["CFBundleDisplayName"], "LessMeet")
        self.assertEqual(info["CFBundleShortVersionString"], "1.0.0")
        self.assertEqual(info.get("LSApplicationCategoryType"), "public.app-category.productivity")
        # Release stamping still requires explicit version/build inputs rather
        # than treating the source template as permission to upload build 1.
        stamped = plistlib.loads(self.info_path.read_bytes())
        self.assertEqual(stamped["CFBundleShortVersionString"], "1.2.3")
        self.assertEqual(stamped["CFBundleVersion"], "42")

    def test_distribution_identity_missing_or_wrong_rejected(self):
        for mode in ("store", "testflight"):
            approval = {**self.approval, "mode": mode}
            values = (*self.values[:4], approval)
            original = plistlib.loads(self.info_path.read_bytes())
            original["LessMeetPackagingMode"] = mode
            self.info_path.write_bytes(plistlib.dumps(original))
            store.validate_bundle(self.app, values, mode)
            for key in ("CFBundleName", "CFBundleDisplayName", "LSApplicationCategoryType"):
                for value in (None, "wrong"):
                    with self.subTest(mode=mode, key=key, value=value):
                        info = dict(original)
                        if value is None:
                            info.pop(key, None)
                        else:
                            info[key] = value
                        self.info_path.write_bytes(plistlib.dumps(info))
                        with self.assertRaises(store.Invalid):
                            store.validate_bundle(self.app, values, mode)
            self.info_path.write_bytes(plistlib.dumps(original))

    def test_stamp_and_bundle_metadata_rejection(self):
        store.validate_bundle(self.app, self.values)
        for key in ("CFBundleVersion", "CFBundleShortVersionString", "CFBundleIconFile", "CFBundleIdentifier",
                    "LessMeetPackagingMode", "ConvexSiteURL", "LSMinimumSystemVersion", "CFBundleURLTypes"):
            original = self.info_path.read_bytes()
            info = plistlib.loads(original)
            info[key] = "wrong"
            self.info_path.write_bytes(plistlib.dumps(info))
            with self.subTest(key=key), self.assertRaises(store.Invalid):
                store.validate_bundle(self.app, self.values)
            self.info_path.write_bytes(original)
        (self.app / "Contents/_CodeSignature").mkdir()
        with self.assertRaises(store.Invalid):
            store.stamp(self.app, self.values)

    def test_installer_identity_policy(self):
        output = '1) ' + FINGERPRINT + ' "' + INSTALLER + '"'
        self.assertEqual(store.installer_identity(output, FINGERPRINT), (FINGERPRINT, INSTALLER))
        for name in ("Apple Distribution: Synthetic (63M98WD275)", "Developer ID Installer: Synthetic (63M98WD275)",
                     "Mac Installer Distribution: Synthetic (WRONGTEAM)"):
            with self.assertRaises(store.Invalid):
                store.installer_identity('1) ' + FINGERPRINT + ' "' + name + '"', FINGERPRINT)
        with self.assertRaises(store.Invalid):
            store.installer_identity(output + '\n2) ' + '0' * 40 + ' "' + INSTALLER + '"', INSTALLER)
        with self.assertRaises(store.Invalid):
            store.installer_identity(output + '\n2) ' + '0' * 40 + ' "' + INSTALLER + '"', FINGERPRINT)

    def test_package_isolated_and_no_upload_install_or_app_signing(self):
        before = {str(p.relative_to(self.app)): p.read_bytes() for p in self.app.rglob("*") if p.is_file()}
        output = self.folder / "new-output"
        with patch.object(store, "run", side_effect=self.fake_run), patch.object(store, "verify_signed_app") as verify:
            store.package(self.app, output, FINGERPRINT, self.values)
        self.assertEqual(verify.call_count, 2)
        self.assertTrue(all(call.args[0] != self.app for call in verify.call_args_list))
        self.assertEqual(before, {str(p.relative_to(self.app)): p.read_bytes() for p in self.app.rglob("*") if p.is_file()})
        self.assertTrue((output / "LessMeet.pkg").is_file())
        report = json.loads((output / "validation.json").read_text())
        self.assertEqual(report["pkg_sha256"], store.digest((output / "LessMeet.pkg").read_bytes()))
        command = next(c for c in self.calls if c[0] == "/usr/bin/productbuild")
        self.assertEqual(command[1], "--component")
        self.assertEqual(command[3:6], ["/Applications", "--sign", INSTALLER])
        self.assertEqual({c[0] for c in self.calls}, {"/usr/bin/security", "/usr/bin/productbuild", "/usr/sbin/pkgutil"})

    def test_package_failures_never_retain_pkg_or_overwrite(self):
        for failure in ("signature", "productbuild", "pkgutil", "wrong-installer", "untrusted"):
            output = self.folder / failure
            def fake(args):
                if failure == "productbuild" and args[0] == "/usr/bin/productbuild":
                    raise store.Invalid("synthetic failure")
                if args[0] == "/usr/sbin/pkgutil":
                    if failure == "pkgutil":
                        raise store.Invalid("synthetic failure")
                    if failure == "wrong-installer":
                        return b"Status: signed by a certificate trusted by macOS\n  1. Other\n"
                    if failure == "untrusted":
                        return ("Status: no signature\n  1. " + INSTALLER).encode()
                return self.fake_run(args)
            with patch.object(store, "run", side_effect=fake), \
                    patch.object(store, "verify_signed_app", side_effect=store.Invalid("bad signature") if failure == "signature" else None), \
                    self.assertRaises(store.Invalid):
                store.package(self.app, output, FINGERPRINT, self.values)
            self.assertFalse((output / "LessMeet.pkg").exists())
        with patch.object(store, "run") as command, self.assertRaises(store.Invalid):
            store.package(self.app, self.folder, FINGERPRINT, self.values)
        command.assert_not_called()

    def test_symlink_and_nested_output_rejected_before_signing(self):
        with patch.object(store, "run") as command, self.assertRaises(store.Invalid):
            store.package(self.app, self.app / "output", FINGERPRINT, self.values)
        command.assert_not_called()
        (self.app / "Contents/link").symlink_to(self.icon)
        with patch.object(store, "run") as command, self.assertRaises(store.Invalid):
            store.package(self.app, self.folder / "output", FINGERPRINT, self.values)
        command.assert_not_called()

    def test_real_build_preflight_fails_before_identity_or_compilation(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            shutil.copytree(ROOT / "scripts", root / "scripts")
            result = subprocess.run(["bash", "scripts/build-app.sh", "store", "--preflight"], cwd=root,
                                    env={**environment(), **STORE_PUBLIC}, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("LESSMEET_VERSION", result.stderr)
            self.assertFalse((root / "dist").exists())

    def test_signed_app_boundary_exact_certificate_profile_and_entitlements(self):
        import datetime as dt
        data = profile("store")
        data["CreationDate"] = dt.datetime.now() - dt.timedelta(days=1)
        data["ExpirationDate"] = dt.datetime.now() + dt.timedelta(days=1)
        ent = {"com.apple.application-identifier": "OLDPREFIX1.com.lessmeet.app",
               "com.apple.developer.team-identifier": store.signing.TEAM,
               "com.apple.security.app-sandbox": True, "com.apple.security.network.client": True,
               "com.apple.security.device.audio-input": True}
        def fake(args):
            self.calls.append(args)
            if args[0] == "/usr/bin/lipo":
                return b"arm64 x86_64\n"
            if "--verify" in args:
                self.assertIn("--all-architectures", args)
                self.assertIn("--test-requirement", args)
                return b""
            if "--entitlements" in args:
                return plistlib.dumps(ent)
            if "cms" in args:
                return plistlib.dumps(data)
            if any(str(arg).startswith("--extract-certificates") for arg in args):
                self.assertNotIn("--extract-certificates", args,
                                 "codesign optional prefix must bind with '='")
                self.assertEqual(len(args), 6)
                self.assertEqual(args[:3], ["/usr/bin/codesign", "--display", "--arch"])
                self.assertIn(args[3], ("arm64", "x86_64"))
                self.assertTrue(args[4].startswith("--extract-certificates="))
                prefix = Path(args[4].split("=", 1)[1])
                self.assertEqual(prefix.name, "cert")
                self.assertTrue(prefix.parent.is_dir())
                self.assertEqual(args[5], self.app)
                Path(str(prefix) + "0").write_bytes(DER)
                return b""
            raise AssertionError(args)
        with patch.object(store, "run", side_effect=fake), \
                patch.object(store.signing, "certificate_metadata", return_value=cert("store")):
            store.verify_signed_app(self.app)
            displayed = [args[3] for args in self.calls if "--entitlements" in args]
            self.assertEqual(displayed, ["arm64", "x86_64"])
            self.calls.clear()
            store.verify_signed_app(self.app, "testflight")
            self.assertEqual([args[3] for args in self.calls if "--entitlements" in args], ["arm64", "x86_64"])
            ent["get-task-allow"] = True
            with self.assertRaises(store.Invalid):
                store.verify_signed_app(self.app)
            with self.assertRaises(store.Invalid):
                store.verify_signed_app(self.app, "testflight")
            del ent["get-task-allow"]
            data["DeveloperCertificates"] = [b"not the signature leaf"]
            with self.assertRaises(store.Invalid):
                store.verify_signed_app(self.app)
            with self.assertRaises(store.Invalid):
                store.verify_signed_app(self.app, "testflight")


store_run = store.run

if __name__ == "__main__":
    unittest.main()
