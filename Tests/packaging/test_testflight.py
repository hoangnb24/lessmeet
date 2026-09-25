"""Synthetic beta fixtures only; never reads operator signing inputs."""
import json
import os
import plistlib
import unittest
from unittest.mock import patch

import test_store_package as fixtures
import test_packaging as packaging
from test_store_package import store, ICON
from test_packaging import PUBLIC, FINGERPRINT, profile, cert, NOW, signing


class TestFlightTests(unittest.TestCase):
    write_approval = fixtures.StoreTests.write_approval
    fake_run = fixtures.StoreTests.fake_run

    def setUp(self):
        fixtures.StoreTests.setUp(self)
        self.public = {**PUBLIC, "LESSMEET_PRIVACY_URL": "", "LESSMEET_TERMS_URL": ""}
        self.approval = {k: v for k, v in self.approval.items()
                         if not k.startswith("production_") and k != "published_legal_evidence"}
        self.approval.update(mode="testflight", public_configuration=self.public,
                             internal_audience="internal-only", backend_evidence="synthetic development backend",
                             auth_billing_evidence="synthetic alignment",
                             internal_unpublished_legal_acknowledgement="synthetic internal testing only",
                             distribution_control_acknowledgement="manual-app-store-connect-internal-group-selection")
        self.write_approval()
        del self.env["LESSMEET_STORE_APPROVAL"]
        self.env.update(self.public, LESSMEET_TESTFLIGHT_APPROVAL=str(self.approval_path))
        self.values = ("1.2.3", "42", self.public, ICON, self.approval)
        self.info.update({p: self.public[k] for k, p in store.PUBLIC.items()})
        self.info["LessMeetPackagingMode"] = "testflight"
        self.info_path.write_bytes(plistlib.dumps(self.info))
        store.stamp(self.app, self.values, "testflight")

    def test_approved_dev_inputs_and_absent_legal(self):
        with patch.dict(os.environ, self.env, clear=True), patch.object(store, "run", side_effect=self.fake_run):
            self.assertEqual(store.inputs("testflight"), self.values)
        self.assertEqual({c[0] for c in self.calls}, {"node", "/usr/bin/iconutil", "/usr/bin/sips"})
        store.validate_bundle(self.app, self.values, "testflight")

    def test_every_binding_and_evidence_is_required(self):
        for key in self.approval:
            changed = {**self.approval, key: None}
            self.approval_path.write_text(json.dumps(changed))
            with self.subTest(key=key), patch.dict(os.environ, self.env, clear=True), \
                    patch.object(store, "run", side_effect=self.fake_run), self.assertRaises(store.Invalid):
                store.inputs("testflight")

    def test_all_actual_public_values_bound_including_optional_legal(self):
        for key in store.PUBLIC:
            with self.subTest(key=key), patch.dict(os.environ, {**self.env, key: "changed"}, clear=True), \
                    patch.object(store, "run", side_effect=self.fake_run), self.assertRaises(store.Invalid):
                store.inputs("testflight")

    def test_record_and_mode_mixing_rejected(self):
        for mode, env in [("store", self.env), ("testflight", {**self.env, "LESSMEET_STORE_APPROVAL": str(self.approval_path)})]:
            with patch.dict(os.environ, env, clear=True), patch.object(store, "run") as command, self.assertRaises(store.Invalid):
                store.inputs(mode)
            command.assert_not_called()
        for mode in ["store", "sandbox-dev", "TestFlight"]:
            with self.assertRaises(store.Invalid):
                store.validate_bundle(self.app, self.values, mode)
        self.approval["mode"] = "store"
        self.write_approval()
        with patch.dict(os.environ, self.env, clear=True), self.assertRaises(store.Invalid):
            store.inputs("testflight")

    def test_metadata_and_icon_tamper_rejected(self):
        original = self.info_path.read_bytes()
        for key in ["LessMeetPackagingMode", "CFBundleVersion", "CFBundleShortVersionString", "CFBundleIdentifier", *store.PUBLIC.values()]:
            info = plistlib.loads(original)
            info[key] = "tampered"
            self.info_path.write_bytes(plistlib.dumps(info))
            with self.subTest(key=key), self.assertRaises(store.Invalid):
                store.validate_bundle(self.app, self.values, "testflight")
        self.info_path.write_bytes(original)
        (self.app / "Contents/Resources/LessMeet.icns").write_bytes(b"changed")
        with self.assertRaises(store.Invalid):
            store.validate_bundle(self.app, self.values, "testflight")

    def test_package_records_distinct_mode(self):
        output = self.folder / "beta-output"
        with patch.object(store, "run", side_effect=self.fake_run), patch.object(store, "verify_signed_app") as verify:
            store.package(self.app, output, FINGERPRINT, self.values, "testflight")
        self.assertEqual(json.loads((output / "validation.json").read_text())["mode"], "testflight")
        self.assertEqual([c.args[1] for c in verify.call_args_list], ["testflight", "testflight"])

    def test_distribution_policy_identical_to_store(self):
        for mode in ["store", "testflight"]:
            self.assertEqual(signing.validate(profile("store"), mode, FINGERPRINT, cert("store"), now=NOW),
                             signing.validate(profile("store"), "store", FINGERPRINT, cert("store"), now=NOW))
            for data, certificate in [(profile(), cert()), (profile(), cert("store")),
                                      (profile("store"), cert()),
                                      (profile("store"), {**cert("store"), "team": "wrong"})]:
                with self.assertRaises(signing.Invalid):
                    signing.validate(data, mode, FINGERPRINT, certificate, now=NOW)


class BetaConfigTests(unittest.TestCase):
    setUp = packaging.ConfigTests.setUp
    configure = packaging.ConfigTests.configure

    def test_testflight_no_env_fallback_and_legal_optional(self):
        (self.folder / ".env.local").write_text("\n".join(f"{k}={v}" for k, v in PUBLIC.items()))
        self.assertNotEqual(self.configure({}, "testflight", check=True).returncode, 0)
        values = {k: v for k, v in PUBLIC.items() if k not in ["LESSMEET_PRIVACY_URL", "LESSMEET_TERMS_URL"]}
        self.assertEqual(self.configure(values, "testflight").returncode, 0)
        self.assertEqual(plistlib.loads(self.plist.read_bytes())["LessMeetPackagingMode"], "testflight")


class BetaBuildTests(unittest.TestCase):
    setUp = packaging.BuildFlowTests.setUp
    build = packaging.BuildFlowTests.build
    stub = packaging.BuildFlowTests.stub
    fake_signing_boundary = packaging.BuildFlowTests.fake_signing_boundary

    def test_beta_isolated_and_missing_approval_stops_before_signing(self):
        result = self.build("testflight", values=PUBLIC)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.folder / "invoked").exists())
        self.assertFalse((self.folder / "dist/testflight").exists())
        self.fake_signing_boundary()
        result = self.build("testflight", values=PUBLIC)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.folder / "dist/testflight/LessMeet.app/Contents/embedded.provisionprofile").is_file())
        self.assertEqual((self.folder / "dist/LessMeet.app/sentinel").read_text(), "existing dev app")
