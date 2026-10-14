"""Offline signing/notarization contract tests. All keys, profiles and responses are synthetic."""
import base64
import datetime as dt
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile
from test_github_release import fixture_plan, fixture_zip, release

ROOT = Path(__file__).resolve().parents[2]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


signer = load("signer_test", "sign-local-app.py")
ci = load("ci_sign_test", "ci-sign-release.py")
DER = b"synthetic-certificate"
FP = hashlib.sha1(DER).hexdigest().upper()
NOW = dt.datetime.now(dt.timezone.utc)


def profile(dev=False):
    result = {"Platform": ["OSX"], "TeamIdentifier": [signer.policy.TEAM],
              "ApplicationIdentifierPrefix": ["PREFIX1234"], "CreationDate": NOW - dt.timedelta(days=1),
              "ExpirationDate": NOW + dt.timedelta(days=1), "DeveloperCertificates": [DER],
              "Entitlements": {"com.apple.application-identifier": "PREFIX1234.com.lessmeet.app",
                               "com.apple.developer.team-identifier": signer.policy.TEAM,
                               "keychain-access-groups": ["PREFIX1234.*"]}}
    result.update({"ProvisionedDevices": ["SYNTHETIC-DEVICE"]} if dev else {"ProvisionsAllDevices": True})
    return result


def certificate(dev=False):
    return {"valid": True, "team": signer.policy.TEAM,
            "name": ("Apple Development:" if dev else "Developer ID Application:") + " Synthetic"}


def signed_plan():
    value = fixture_plan()
    value.update(schema=3, tag=value["tag"].replace("main-build-", "main-signed-"), readiness=release.SIGNED_READINESS)
    value["archive_name"] = "LessMeet-" + value["tag"] + "-macos-arm64-developer-id.zip"
    return value


def signed_zip():
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as archive:
        for name, data in {"Info.plist": plistlib.dumps({"CFBundleIdentifier": "com.lessmeet.app", "LessMeetPackagingMode": "developer-id"}),
                           "MacOS/LessMeet": b"synthetic-code", "embedded.provisionprofile": b"synthetic-profile"}.items():
            archive.writestr("LessMeet.app/Contents/" + name, data)
    return stream.getvalue()


def verification():
    return {"certificate_sha1": FP, "team_id": signer.policy.TEAM,
            "profile_sha256": release.digest(b"synthetic-profile"), "executable_sha256": release.digest(b"synthetic-code"),
            "notarization_id": "11111111-2222-3333-4444-555555555555", "status": "Accepted", "stapled": True}


class ProfilePolicyTests(unittest.TestCase):
    def test_modes_do_not_confuse_development_and_distribution(self):
        for dev, mode in ((True, "signed-local"), (False, "developer-id")):
            result = signer.policy.validate(profile(dev), mode, FP, certificate(dev), now=NOW)
            self.assertEqual(set(result), {"com.apple.application-identifier", "com.apple.developer.team-identifier"})
            with self.assertRaises(signer.Invalid):
                signer.policy.validate(profile(not dev), mode, FP, certificate(not dev), now=NOW)

    def test_developer_id_rejects_profile_and_certificate_mismatch(self):
        for key, value in (("ProvisionsAllDevices", False), ("ProvisionedDevices", ["DEVICE"]),
                           ("ExpirationDate", NOW), ("TeamIdentifier", ["WRONG"]), ("DeveloperCertificates", [])):
            p = profile()
            p[key] = value
            with self.subTest(key=key), self.assertRaises(signer.Invalid):
                signer.policy.validate(p, "developer-id", FP, certificate(), now=NOW)
        for change in ({"valid": False}, {"team": "WRONG"}, {"name": "Developer ID Installer: Synthetic"}):
            with self.assertRaises(signer.Invalid):
                signer.policy.validate(profile(), "developer-id", FP, {**certificate(), **change}, now=NOW)
        p = profile()
        p["Entitlements"]["get-task-allow"] = True
        with self.assertRaises(signer.Invalid):
            signer.policy.validate(p, "developer-id", FP, certificate(), now=NOW)

    def test_inputs_are_minimal_snapshot_and_exact_fingerprint(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / "profile"
            path.write_bytes(b"synthetic-CMS")
            def decode(args, **kwargs):
                self.assertEqual(Path(args[-1]).read_bytes(), b"synthetic-CMS")
                path.write_bytes(b"changed")
                return plistlib.dumps(profile(True))
            with patch.object(signer, "run", side_effect=decode), patch.object(signer.policy, "certificate_metadata", return_value=certificate(True)):
                original, entitlements = signer.inputs(path, FP)
            self.assertEqual(original, b"synthetic-CMS")
            self.assertEqual(len(entitlements), 3)
            self.assertNotIn("get-task-allow", entitlements)
            self.assertNotIn("keychain-access-groups", entitlements)
            for invalid in ("-", "", "Apple Development: Synthetic"):
                with self.assertRaises(signer.Invalid):
                    signer.inputs(path, invalid)

    def test_signer_failure_never_promotes_or_modifies_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / "Input.app"
            source.mkdir()
            (source / "keep").write_text("original")
            output = root / "Output.app"
            with patch.object(signer.build, "verify_app"), patch.object(signer, "inputs", return_value=(b"profile", {})), \
                 patch.object(signer, "run", side_effect=signer.Invalid("synthetic failure")):
                with self.assertRaises(signer.Invalid):
                    signer.sign(source, output, root / "profile", FP)
            self.assertFalse(output.exists())
            self.assertEqual((source / "keep").read_text(), "original")
            output.mkdir()
            with patch.object(signer.build, "verify_app") as verify:
                with self.assertRaises(signer.Invalid):
                    signer.sign(source, output, root / "profile", FP)
                verify.assert_not_called()

    def test_signer_children_do_not_inherit_credentials(self):
        fake = subprocess.CompletedProcess([], 0, b"ok", b"")
        with patch.dict(os.environ, {name: "SYNTHETIC-SECRET" for name in ci.SECRET_NAMES}), \
             patch.object(signer.subprocess, "run", return_value=fake) as child:
            signer.run(["synthetic"])
        self.assertNotIn("SYNTHETIC-SECRET", str(child.call_args.kwargs["env"]))

    def test_verify_extracts_leaf_with_optional_argument_syntax(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory).resolve() / "Fixture.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.lessmeet.app", "LessMeetPackagingMode": "signed-local"}))
            (app / "Contents/MacOS/LessMeet").write_bytes(b"code")
            (app / "Contents/embedded.provisionprofile").write_bytes(b"profile")
            entitlements = {"com.apple.security.device.audio-input": True}
            def command(args, **kwargs):
                if args[0] == "/usr/bin/lipo":
                    return b"arm64"
                if "--entitlements" in args:
                    return plistlib.dumps(entitlements)
                prefixes = [str(a).split("=", 1)[1] for a in args if str(a).startswith("--extract-certificates=")]
                if prefixes:
                    Path(prefixes[0] + "0").write_bytes(DER)
                return b""
            with patch.object(signer, "run", side_effect=command), patch.object(signer.build, "verify_resources"):
                self.assertEqual(signer.verify(app, FP, b"profile", entitlements)["signing"], "profile-backed-development")
                with self.assertRaises(signer.Invalid):
                    signer.verify(app, "0" * 40, b"profile", entitlements)
                with self.assertRaises(signer.Invalid):
                    signer.verify(app, FP, b"changed profile", entitlements)


class SignedManifestTests(unittest.TestCase):
    def test_signed_plan_prepare_never_archives_or_seals_adhoc_bytes(self):
        build = signer.build
        calls = []
        def command(args, stage, **kwargs):
            calls.append(stage)
            return "Xcode 26.6\nBuild version 17F113\n" if stage == "Xcode check" else ""
        with tempfile.TemporaryDirectory() as directory, patch.object(build, "load_plan", return_value=signed_plan()), \
             patch.object(build.platform, "system", return_value="Darwin"), patch.object(build.platform, "machine", return_value="arm64"), \
             patch.object(build, "run", side_effect=command), patch.object(build, "verify_app", return_value={}):
            output = Path(directory) / "out"
            with self.assertRaises(build.BuildError):
                build.build(Path("plan"), output, execute=True)
            result = build.build(Path("plan"), output, execute=True, prepare=True)
            self.assertEqual(result["mode"], "prepared-unsigned")
            self.assertNotIn("Archive", calls)
            self.assertNotIn("Seal release inputs", calls)
            self.assertFalse(output.exists())

    def test_schema_and_tag_namespace_separate_historical_bytes(self):
        plan = signed_plan()
        release.validate_plan(plan)
        self.assertNotEqual(plan["tag"], fixture_plan()["tag"])
        plan["archive_name"] = fixture_plan()["archive_name"]
        with self.assertRaises(release.Invalid):
            release.validate_plan(plan)

    def test_development_profile_cannot_be_sealed_as_adhoc(self):
        with self.assertRaises(release.Invalid):
            release.validate_zip(fixture_zip(extra=[("LessMeet.app/Contents/embedded.provisionprofile", b"synthetic")]))
        with self.assertRaises(release.Invalid):
            release.validate_zip(signed_zip())
        with self.assertRaises(release.Invalid):
            release.validate_zip(fixture_zip(), True)

    def test_seal_requires_bound_accepted_stapled_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            plan = signed_plan()
            plan_path = root / "plan.json"
            plan_path.write_bytes(release.encode(plan))
            archive = root / plan["archive_name"]
            archive.write_bytes(signed_zip())
            receipt_path = root / "receipt.json"
            good = {"source_sha": plan["source_sha"], "archive_sha256": release.digest(archive.read_bytes()), "verification": verification()}
            with self.assertRaises(release.Invalid):
                release.seal(plan_path, archive, root / "missing")
            for changes in ({"status": "Invalid"}, {"stapled": False}, {"profile_sha256": "0" * 64}, {"executable_sha256": "0" * 64}):
                receipt_path.write_bytes(release.encode({**good, "verification": {**verification(), **changes}}))
                with self.assertRaises(release.Invalid):
                    release.seal(plan_path, archive, root / "rejected", receipt_path)
                self.assertFalse((root / "rejected").exists())
            receipt_path.write_bytes(release.encode(good))
            release.seal(plan_path, archive, root / "sealed", receipt_path)
            manifest, files = release.sealed(root / "sealed", plan["source_sha"], plan["repository"])
            self.assertEqual(manifest["signing"], "developer-id")
            self.assertIs(manifest["notarized"], True)
            self.assertEqual(len(files), 4)


class NotaryTests(unittest.TestCase):
    def test_execute_orders_sign_notary_verify_seal_and_cleans_on_failure(self):
        for fail in (False, True, "interrupt", "archive-check"):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                private = root / "private"
                plan_path = root / "plan.json"
                plan_path.write_bytes(release.encode(signed_plan()))
                output = root / "assets"
                calls = []
                values = {name: base64.b64encode(b"synthetic").decode() for name in ci.SECRET_NAMES}
                values.update(LESSMEET_DEVELOPER_ID_CERT_SHA1=FP, LESSMEET_NOTARY_KEY_ID="FAKEKEY123",
                              LESSMEET_NOTARY_ISSUER_ID=verification()["notarization_id"])
                def command(args, **kwargs):
                    calls.append(args)
                    if "create-keychain" in args:
                        Path(args[-1]).write_bytes(b"synthetic")
                    if "delete-keychain" in args:
                        Path(args[-1]).unlink()
                    if "find-identity" in args:
                        return ('1) ' + FP + ' "Developer ID Application: Synthetic"').encode()
                    if args[0] == "/usr/bin/ditto" and "-c" in args:
                        Path(args[-1]).write_bytes(signed_zip())
                    return b""
                def do_sign(*args):
                    calls.append(["sign"])
                def notary(*args):
                    calls.append(["notary"])
                    if fail == "interrupt":
                        raise KeyboardInterrupt()
                    if fail is True:
                        raise ci.Invalid("synthetic-notary-failure")
                    return verification()["notarization_id"]
                def verify(*args):
                    calls.append(["verify"])
                    if fail == "archive-check" and "archive-check" in str(args[0]):
                        raise ci.Invalid("synthetic final-archive failure")
                    return verification()
                with patch.dict(os.environ, values), patch.object(ci.signer, "ROOT", root), \
                     patch.object(ci.signer.build, "load_plan"), patch.object(ci.signer.build, "verify_app"), \
                     patch.object(ci.signer, "inputs", return_value=(b"synthetic-profile", {})), \
                     patch.object(ci.signer, "sign", side_effect=do_sign), patch.object(ci, "notarize", side_effect=notary), \
                     patch.object(ci.signer, "verify", side_effect=verify), patch.object(ci.signer, "run", side_effect=command):
                    if fail:
                        with self.assertRaises(KeyboardInterrupt if fail == "interrupt" else ci.Invalid):
                            ci.execute(plan_path, output, private)
                        self.assertFalse((output / "release.json").exists())
                        if fail != "archive-check":
                            self.assertFalse(output.exists())
                            self.assertNotIn(["verify"], calls)
                    else:
                        ci.execute(plan_path, output, private)
                        release.sealed(output, signed_plan()["source_sha"], signed_plan()["repository"])
                        self.assertLess(calls.index(["sign"]), calls.index(["notary"]))
                        self.assertLess(calls.index(["notary"]), calls.index(["verify"]))
                self.assertFalse(private.exists())
                self.assertTrue(any("delete-keychain" in c for c in calls))

    def test_notary_success_requires_staple_validate_and_assess(self):
        calls = []
        def command(args, **kwargs):
            calls.append(args)
            return json.dumps({"id": verification()["notarization_id"], "status": "Accepted"}).encode() if "submit" in args else b""
        with patch.object(ci.signer, "run", side_effect=command):
            ci.notarize(Path("fixture.app"), Path("submission.zip"), ("fake.p8", "FAKEKEY123", "issuer"))
        self.assertEqual([c[2] for c in calls if c[0] == "xcrun"], ["submit", "staple", "validate"])
        self.assertEqual(calls[-1][0], "/usr/sbin/spctl")
        self.assertIn("--timeout", calls[1])

    def test_notary_failures_do_not_staple(self):
        for response in (b"{}", b"not json", json.dumps({"id": verification()["notarization_id"], "status": "Invalid"}).encode()):
            calls = []
            def command(args, **kwargs):
                calls.append(args)
                return response if "submit" in args else b""
            with patch.object(ci.signer, "run", side_effect=command), self.assertRaises(ci.Invalid):
                ci.notarize(Path("fixture.app"), Path("submission.zip"), ("fake", "fake", "fake"))
            self.assertFalse(any("staple" in c for c in calls))

    def test_staple_validation_and_assessment_fail_closed(self):
        for failing in ("staple", "validate", "--assess"):
            calls = []
            def command(args, **kwargs):
                calls.append(args)
                if failing in args:
                    raise ci.Invalid("synthetic failure")
                return json.dumps({"id": verification()["notarization_id"], "status": "Accepted"}).encode() if "submit" in args else b""
            with patch.object(ci.signer, "run", side_effect=command), self.assertRaises(ci.Invalid):
                ci.notarize(Path("fixture.app"), Path("submission.zip"), ("fake", "fake", "fake"))
            self.assertIn(failing, calls[-1])

    def test_cleanup_keychain_failure_still_removes_credential_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve() / "owned"
            root.mkdir()
            (root / "owner").write_text("LessMeet ephemeral signing\n")
            for name in ("signing.keychain-db", "certificate.p12", "notary.p8", "profile.provisionprofile"):
                (root / name).write_bytes(b"synthetic")
            with patch.object(ci.signer, "run", side_effect=ci.Invalid("synthetic timeout")), self.assertRaises(ci.Invalid):
                ci.cleanup(root)
            self.assertEqual({p.name for p in root.iterdir()}, {"owner", "signing.keychain-db"})
            with patch.object(ci.signer, "run", side_effect=lambda args: Path(args[-1]).unlink()):
                ci.cleanup(root)
            self.assertFalse(root.exists())

    def test_ci_command_refuses_local_host(self):
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(ci.Invalid):
            ci.private_root()

    def test_cleanup_only_removes_owned_run_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve() / "owned"
            root.mkdir()
            (root / "owner").write_text("LessMeet ephemeral signing\n")
            (root / "notary.p8").write_text("synthetic")
            (Path(directory) / "unrelated").write_text("keep")
            with patch.object(ci.signer, "run") as run:
                ci.cleanup(root)
                run.assert_not_called()
            self.assertFalse(root.exists())
            self.assertEqual((Path(directory) / "unrelated").read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
