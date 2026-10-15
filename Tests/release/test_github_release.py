"""Offline fixtures only. No credentials, network, real app or release mutations."""
import copy
import importlib.util
import io
import json
import os
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from unittest.mock import patch
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / ".artifacts/release-automation/helper"
EVIDENCE.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location("github_release", ROOT / "scripts/github-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
SOURCE = "a" * 40
REPOSITORY = "synthetic/lessmeet"


def fixture_plan(sha=SOURCE):
    tag = "main-build-7-" + sha
    return {"schema": 2, "source_sha": sha, "sequence": 7, "tag": tag,
            "archive_name": "LessMeet-" + tag + "-macos-arm64-adhoc.zip", "repository": REPOSITORY,
            "pr_number": 12, "pr_title": "Add transcript search and preserve selection",
            "pr_base_sha": "b" * 40, "pr_head_sha": "f" * 40, "pr_commit_count": 2,
            "commit_shas": ["c" * 40, "f" * 40], "commit_subjects": ["Add transcript search", "Preserve selected transcript"],
            "integration_shape": "linear", "integration_boundary_sha": sha, "coverage": "original-pr-commits",
            "pr_url": "https://github.com/synthetic/lessmeet/pull/12",
            "compare_url": "https://github.com/synthetic/lessmeet/compare/" + "b" * 40 + "..." + "f" * 40,
            "readiness": release.READINESS}


def fixture_zip(marker=b"synthetic-not-an-executable", extra=None):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as archive:
        for name, data in [("LessMeet.app/Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": "com.lessmeet.app.local", "LessMeetPackagingMode": "local"})),
                           ("LessMeet.app/Contents/MacOS/LessMeet", marker), *(extra or [])]:
            info = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data)
    return stream.getvalue()


class FakeGitHub:
    """A persistent remote, including ambiguous successful POST outcomes."""
    def __init__(self):
        self.tag = None
        self.release = None
        self.content = {}
        self.calls = []
        self.create_tag_race = None
        self.create_release_race = None
        self.upload_race = None
        self.ambiguous_upload = False
        self.ambiguous_tag = False
        self.ambiguous_create = False
        self.ambiguous_publish = False
        self.corrupt_download = False
        self.extra_assets = []
        self.race_status = None

    def json(self, method, endpoint, payload=None):
        self.calls.append((method, endpoint, copy.deepcopy(payload)))
        if method == "GET" and endpoint.startswith("git/ref/"):
            if self.tag is None:
                raise release.APIError(404)
            return copy.deepcopy(self.tag)
        if method == "POST" and endpoint == "git/refs":
            self.tag = {"ref": payload["ref"], "object": {"type": "commit", "sha": payload["sha"]}}
            if self.ambiguous_tag:
                self.ambiguous_tag = False
                raise release.Invalid("github-transport-outcome-unknown: rerun failed publish with original artifact")
            if self.create_tag_race:
                if self.create_tag_race == "wrong":
                    self.tag["object"]["sha"] = "d" * 40
                raise release.APIError(self.race_status or 422)
            return copy.deepcopy(self.tag)
        if method == "GET" and endpoint.startswith("releases?"):
            return [copy.deepcopy(self.release)] if self.release is not None else []
        if method == "POST" and endpoint == "releases":
            self.release = {**payload, "id": 41}
            if self.ambiguous_create:
                self.ambiguous_create = False
                raise release.Invalid("github-transport-outcome-unknown: rerun failed publish with original artifact")
            if self.create_release_race:
                if self.create_release_race == "wrong":
                    self.release["target_commitish"] = "d" * 40
                raise release.APIError(self.race_status or 409)
            return copy.deepcopy(self.release)
        if method == "GET" and endpoint.startswith("releases/41/assets?"):
            result = [{"id": i + 1, "name": name, "size": len(data), "state": "uploaded",
                       "digest": "sha256:" + release.digest(data)} for i, (name, data) in enumerate(self.content.items())]
            return result + copy.deepcopy(self.extra_assets)
        if method == "GET" and endpoint == "releases/41":
            return copy.deepcopy(self.release)
        if method == "PATCH" and endpoint == "releases/41":
            assert len(self.content) == 4
            self.release.update(payload)
            if self.ambiguous_publish:
                self.ambiguous_publish = False
                raise release.Invalid("github-transport-outcome-unknown: rerun failed publish with original artifact")
            return copy.deepcopy(self.release)
        raise AssertionError("unexpected fake API operation")

    def upload(self, release_id, name, data):
        self.calls.append(("UPLOAD", name, None))
        assert release_id == 41 and self.release["draft"]
        assert name not in self.content  # No overwrite is permitted.
        self.content[name] = data
        if self.ambiguous_upload:
            self.ambiguous_upload = False
            raise release.Invalid("github-transport-outcome-unknown: rerun failed publish with original artifact")
        if self.upload_race:
            if self.upload_race == "wrong":
                self.content[name] = b"other-writer-bytes"
            raise release.APIError(self.race_status or 422)
        return {}

    def download(self, asset_id):
        self.calls.append(("DOWNLOAD", asset_id, None))
        data = list(self.content.values())[asset_id - 1]
        return b"corrupt" if self.corrupt_download else data

    def mutations(self):
        return [c for c in self.calls if c[0] in ("POST", "PATCH", "UPLOAD", "DELETE")]


class LocalTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp(prefix="case-", dir=EVIDENCE))
        # Keep evidence. Only fresh task-owned fixtures are created.
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, {"GH_TOKEN": "synthetic-test-token", "GITHUB_EVENT_NAME": "pull_request_target"}).start()
        self.value = fixture_plan()
        self.plan_path = self.folder / "plan.json"
        self.plan_path.write_bytes(release.encode(self.value))
        self.archive = self.folder / self.value["archive_name"]
        self.archive.write_bytes(fixture_zip())
        self.directory = self.folder / "sealed"

    def seal(self):
        return release.seal(self.plan_path, self.archive, self.directory)

    def publish(self, api, execute=True):
        return release.publish(self.directory, SOURCE, REPOSITORY, execute, api)

    def test_seal_outside_archive_exact_allowlist(self):
        first = self.seal()
        self.assertEqual(set(p.name for p in self.directory.iterdir()),
                         {self.value["archive_name"], "release.json", "changelog.md", "SHA256SUMS"})
        self.assertEqual(first["archive"]["sha256"], release.digest(self.archive.read_bytes()))
        self.assertEqual(first["architecture"], "arm64")
        self.assertFalse(first["notarized"])
        release.sealed(self.directory, SOURCE, REPOSITORY)

    def test_seal_archive_already_inside_output(self):
        self.directory.mkdir()
        inside = self.directory / self.archive.name
        inside.write_bytes(self.archive.read_bytes())
        before = inside.stat()
        release.seal(self.plan_path, inside, self.directory)
        self.assertEqual(inside.stat().st_ino, before.st_ino)
        self.assertEqual(inside.read_bytes(), self.archive.read_bytes())

    def test_seal_deterministic_bytes(self):
        self.seal()
        other = self.folder / "second"
        release.seal(self.plan_path, self.archive, other)
        self.assertEqual({p.name: p.read_bytes() for p in self.directory.iterdir()},
                         {p.name: p.read_bytes() for p in other.iterdir()})

    def test_seal_missing_failed_build_no_output(self):
        self.archive.unlink()
        with self.assertRaises(release.Invalid):
            self.seal()
        self.assertFalse(self.directory.exists())

    def test_seal_refuses_unrelated_files(self):
        self.directory.mkdir()
        (self.directory / "build.log").write_bytes(b"SYNTHETIC-SECRET")
        with self.assertRaises(release.Invalid):
            self.seal()
        self.assertEqual(set(p.name for p in self.directory.iterdir()), {"build.log"})

    def test_seal_input_symlinks_refused(self):
        link = self.folder / "linked-plan"
        link.symlink_to(self.plan_path)
        with self.assertRaises(release.Invalid):
            release.seal(link, self.archive, self.directory)
        self.directory.symlink_to(self.folder)
        with self.assertRaises(release.Invalid):
            self.seal()

    def test_archive_name_and_structural_allowlist(self):
        for extra in [("private.log", b"private"), ("LessMeet.app/../private.log", b"private"),
                      ("LessMeet.app/.codex/state", b"private"), ("LessMeet.app/Contents//file", b"x")]:
            with self.subTest(extra=extra[0]), self.assertRaises(release.Invalid):
                release.validate_zip(fixture_zip(extra=[extra]))
        with self.assertRaises(release.Invalid):
            release.validate_zip(b"failed-build-not-a-zip")

    def test_zip_safe_relative_link_and_unsafe_link(self):
        for target, valid in [("../Resources/mlx.metallib", True), ("/private/secret", False), ("../../../secret", False)]:
            stream = io.BytesIO(fixture_zip())
            with zipfile.ZipFile(stream, "a") as archive:
                info = zipfile.ZipInfo("LessMeet.app/Contents/MacOS/mlx.metallib")
                info.external_attr = 0o120777 << 16
                archive.writestr(info, target)
            if valid:
                release.validate_zip(stream.getvalue())
            else:
                with self.assertRaises(release.Invalid):
                    release.validate_zip(stream.getvalue())

    def test_derived_names_source_and_sequence_strict(self):
        for key, bad in [("source_sha", SOURCE.upper()), ("source_sha", "a" * 39),
                         ("sequence", "7"), ("sequence", True), ("sequence", 0),
                         ("tag", "main-build-7-short"), ("archive_name", "../../private.zip"),
                         ("repository", "synthetic/../private"), ("pr_number", True),
                         ("pr_url", "https://evil.invalid/secret"), ("readiness", "E2E passed")]:
            value = {**self.value, key: bad}
            with self.subTest(key=key, bad=bad), self.assertRaises(release.Invalid):
                release.validate_plan(value)

    def test_duplicate_json_keys_refused(self):
        with self.assertRaises(release.Invalid):
            release.decode(b'{"schema":1,"schema":2}')

    def test_default_dry_run_no_api_or_token_access(self):
        self.seal()
        with patch.object(release, "GitHub", side_effect=AssertionError("network forbidden")):
            result = release.publish(self.directory, SOURCE, REPOSITORY)
        self.assertEqual(result["status"], "dry-run")

    def test_cli_offline_dry_run(self):
        self.seal()
        process = subprocess.run([sys.executable, str(ROOT / "scripts/github-release.py"), "publish",
                                  "--directory", str(self.directory), "--expected-sha", SOURCE, "--repo", REPOSITORY],
                                 capture_output=True, env={**os.environ, "GH_TOKEN": "", "PYTHONDONTWRITEBYTECODE": "1"}, timeout=20)
        self.assertEqual(process.returncode, 0)
        self.assertEqual(json.loads(process.stdout)["status"], "dry-run")
        (self.folder / "dry-run.log").write_bytes(process.stdout)

    def test_publish_rejects_tamper_extra_symlink_before_network(self):
        self.seal()
        api = FakeGitHub()
        for name in ["release.json", "changelog.md", "SHA256SUMS", self.archive.name]:
            path = self.directory / name
            original = path.read_bytes()
            path.write_bytes(original + b"tamper")
            with self.subTest(name=name), self.assertRaises(release.Invalid):
                self.publish(api)
            self.assertEqual(api.calls, [])
            path.write_bytes(original)
        extra = self.directory / "screenshot.png"
        extra.write_bytes(b"x")
        with self.assertRaises(release.Invalid):
            self.publish(api)
        extra.unlink()
        path = self.directory / "changelog.md"
        path.unlink()
        path.symlink_to(self.plan_path)
        with self.assertRaises(release.Invalid):
            self.publish(api)
        self.assertEqual(api.calls, [])

    def test_expected_binding_rejected_before_api(self):
        self.seal()
        for sha, repo in [("d" * 40, REPOSITORY), (SOURCE, "other/repo")]:
            api = FakeGitHub()
            with self.assertRaises(release.Invalid):
                release.publish(self.directory, sha, repo, True, api)
            self.assertEqual(api.calls, [])

    def test_create_order_and_verify_before_publish(self):
        self.seal()
        api = FakeGitHub()
        self.assertEqual(self.publish(api)["status"], "published")
        mutations = api.mutations()
        self.assertEqual([c[:2] for c in mutations[:2]], [("POST", "git/refs"), ("POST", "releases")])
        self.assertEqual(sum(c[0] == "UPLOAD" for c in mutations), 4)
        self.assertEqual(mutations[-1][0], "PATCH")
        self.assertEqual(mutations[1][2]["make_latest"], "false")
        self.assertEqual(mutations[1][2]["target_commitish"], SOURCE)
        patch_index = next(i for i, c in enumerate(api.calls) if c[0] == "PATCH")
        self.assertEqual(sum(c[0] == "DOWNLOAD" for c in api.calls[:patch_index]), 3)

    def test_complete_rerun_no_mutations(self):
        self.seal()
        api = FakeGitHub()
        self.publish(api)
        api.calls.clear()
        self.assertEqual(self.publish(api)["status"], "already-published")
        self.assertEqual(api.mutations(), [])

    def test_created_release_can_publish_before_collection_lists_it(self):
        class DelayedCollection(FakeGitHub):
            def json(self, method, endpoint, payload=None):
                result = super().json(method, endpoint, payload)
                if method == "GET" and endpoint.startswith("releases?"):
                    return []
                return result

        self.seal()
        api = DelayedCollection()
        self.assertEqual(self.publish(api)["status"], "published")
        self.assertFalse(api.release["draft"])
        self.assertEqual(api.content, {path.name: path.read_bytes() for path in self.directory.iterdir()})
        self.assertEqual(api.release["target_commitish"], "a" * 40)

    def test_create_response_binding_is_checked_before_upload(self):
        class WrongCreateResponse(FakeGitHub):
            def json(self, method, endpoint, payload=None):
                result = super().json(method, endpoint, payload)
                if method == "POST" and endpoint == "releases":
                    result["body"] = "A different release body"
                return result

        self.seal()
        api = WrongCreateResponse()
        with self.assertRaisesRegex(release.Invalid, "release-binding-mismatch"):
            self.publish(api)
        self.assertTrue(api.release["draft"])
        self.assertEqual(api.content, {})

    def test_binding_failure_names_only_the_mismatched_field(self):
        valid = {"id": 41, "draft": True, "tag_name": self.value["tag"],
                 "target_commitish": SOURCE, "name": self.value["tag"],
                 "prerelease": True, "body": release.changelog(self.value).decode()}
        for field, wrong in [("id", True), ("draft", 1), ("tag_name", "wrong-tag"),
                             ("target_commitish", "d" * 40), ("name", "wrong-name"),
                             ("prerelease", 1), ("body", "SYNTHETIC-SECRET")]:
            with self.subTest(field=field), self.assertRaises(release.Invalid) as error:
                release.release_matches({**valid, field: wrong}, self.value)
            self.assertEqual(str(error.exception), "release-binding-mismatch: " + field)
        with self.assertRaises(release.Invalid) as error:
            release.release_matches(None, self.value)
        self.assertEqual(str(error.exception), "release-binding-mismatch: missing-or-invalid-release")

    def test_duplicate_binding_after_create_stops_before_upload(self):
        class DuplicateAfterCreate(FakeGitHub):
            def json(self, method, endpoint, payload=None):
                result = super().json(method, endpoint, payload)
                if method == "GET" and endpoint.startswith("releases?") and result:
                    return result + [{**result[0], "id": 42}]
                return result

        self.seal()
        api = DuplicateAfterCreate()
        with self.assertRaisesRegex(release.Invalid, "duplicate-release-binding"):
            self.publish(api)
        self.assertTrue(api.release["draft"])
        self.assertEqual(api.content, {})

    def test_rerun_uses_sealed_title_and_subjects_without_current_pr_or_git(self):
        self.seal()
        api = FakeGitHub()
        api.ambiguous_upload = True
        with self.assertRaises(release.Invalid):
            self.publish(api)
        old_notes = (self.directory / "changelog.md").read_bytes()
        self.value["pr_title"] = "A title edited after the event"
        self.value["commit_subjects"][0] = "This is not the captured commit subject"
        self.plan_path.write_bytes(release.encode(self.value))
        with patch.object(release, "plan", side_effect=AssertionError("must use sealed bytes")), \
             patch.object(release, "git", side_effect=AssertionError("PR refs may now be unavailable")):
            self.assertEqual(self.publish(api)["status"], "published")
            api.calls.clear()
            self.assertEqual(self.publish(api)["status"], "already-published")
        self.assertEqual(api.mutations(), [])
        self.assertEqual(api.release["body"].encode(), old_notes)
        self.assertIn(b"Add transcript search", old_notes)
        self.assertNotIn(b"edited after", old_notes)

    def test_different_provenance_snapshot_cannot_rewrite_existing_release(self):
        self.seal()
        api = FakeGitHub()
        self.publish(api)
        api.calls.clear()
        self.value["pr_title"] = "Different event title"
        self.plan_path.write_bytes(release.encode(self.value))
        changed = self.folder / "different-snapshot"
        release.seal(self.plan_path, self.archive, changed)
        with self.assertRaisesRegex(release.Invalid, "release-binding-mismatch"):
            release.publish(changed, SOURCE, REPOSITORY, True, api)
        self.assertEqual(api.mutations(), [])

    def test_old_schema_requires_explicit_migration_not_silent_reinterpretation(self):
        self.value["schema"] = 1
        with self.assertRaisesRegex(release.Invalid, "invalid-plan-schema"):
            release.validate_plan(self.value)

    def test_changelog_renders_title_and_subject_attack_as_inert_text(self):
        self.value["pr_title"] = release.canonical_text("Fix `` </code><img src=x> @team\n# injected")
        self.value["commit_subjects"][0] = release.canonical_text("[click](javascript:alert(1)) @owner/repo")
        self.plan_path.write_bytes(release.encode(self.value))
        self.seal()
        notes = (self.directory / "changelog.md").read_text()
        self.assertIn(release.inert_text(self.value["pr_title"]), notes)
        self.assertIn(release.inert_text(self.value["commit_subjects"][0]), notes)
        self.assertNotIn("@team", notes)
        self.assertNotIn("@owner", notes)
        self.assertNotIn("\n# injected", notes)
        self.assertIn("https://github.com/synthetic/lessmeet/pull/12", notes)

    def test_complete_rerun_accepts_different_rebuild_only_after_remote_validation(self):
        self.seal()
        api = FakeGitHub()
        self.publish(api)
        second = self.folder / "rebuilt"
        self.archive.write_bytes(fixture_zip(b"different-rebuild"))
        release.seal(self.plan_path, self.archive, second)
        api.calls.clear()
        self.assertEqual(release.publish(second, SOURCE, REPOSITORY, True, api)["status"], "already-published")
        self.assertEqual(api.mutations(), [])

    def test_wrong_or_annotated_tag_never_retargeted(self):
        self.seal()
        for typ, sha in [("commit", "d" * 40), ("tag", SOURCE)]:
            api = FakeGitHub()
            api.tag = {"ref": "refs/tags/" + self.value["tag"], "object": {"type": typ, "sha": sha}}
            with self.subTest(typ=typ), self.assertRaises(release.Invalid):
                self.publish(api)
            self.assertEqual(api.mutations(), [])

    def test_tag_create_race_matching_and_wrong(self):
        self.seal()
        api = FakeGitHub()
        api.create_tag_race = "matching"
        self.assertEqual(self.publish(api)["status"], "published")
        wrong = FakeGitHub()
        wrong.create_tag_race = "wrong"
        with self.assertRaises(release.Invalid):
            self.publish(wrong)
        self.assertEqual([c[:2] for c in wrong.mutations()], [("POST", "git/refs")])

    def test_release_create_race_matching_and_wrong(self):
        self.seal()
        api = FakeGitHub()
        api.create_release_race = "matching"
        self.assertEqual(self.publish(api)["status"], "published")
        wrong = FakeGitHub()
        wrong.create_release_race = "wrong"
        with self.assertRaises(release.Invalid):
            self.publish(wrong)
        self.assertFalse(any(c[0] in ("UPLOAD", "PATCH") for c in wrong.calls))

    def test_upload_race_matching_and_wrong(self):
        self.seal()
        api = FakeGitHub()
        api.upload_race = "matching"
        self.assertEqual(self.publish(api)["status"], "published")
        wrong = FakeGitHub()
        wrong.upload_race = "wrong"
        with self.assertRaises(release.Invalid):
            self.publish(wrong)
        self.assertFalse(any(c[0] == "PATCH" for c in wrong.calls))

    def test_ambiguous_upload_recovers_next_call_without_duplicate_upload(self):
        self.seal()
        api = FakeGitHub()
        api.ambiguous_upload = True
        with self.assertRaises(release.Invalid):
            self.publish(api)
        uploaded = next(iter(api.content))
        api.calls.clear()
        self.assertEqual(self.publish(api)["status"], "published")
        self.assertFalse(any(c[:2] == ("UPLOAD", uploaded) for c in api.calls))

    def test_ambiguous_create_and_publish_recover(self):
        self.seal()
        for flag in ("ambiguous_create", "ambiguous_publish"):
            api = FakeGitHub()
            setattr(api, flag, True)
            with self.subTest(flag=flag), self.assertRaises(release.Invalid):
                self.publish(api)
            api.calls.clear()
            self.publish(api)
            self.assertFalse(any(c[:2] == ("POST", "releases") for c in api.calls))

    def test_partial_draft_requires_original_bytes(self):
        self.seal()
        api = FakeGitHub()
        api.ambiguous_upload = True
        with self.assertRaises(release.Invalid):
            self.publish(api)
        api.content[self.archive.name] = b"wrong-prior-build"
        api.calls.clear()
        with self.assertRaisesRegex(release.Invalid, "rerun the failed publish job retaining the original"):
            self.publish(api)
        self.assertEqual(api.mutations(), [])

    def test_starter_unexpected_duplicate_and_missing_digest_fail_closed(self):
        self.seal()
        for asset in [
            {"id": 50, "name": "private.log", "state": "uploaded", "size": 1, "digest": "sha256:" + "e" * 64},
            {"id": 50, "name": "release.json", "state": "starter", "size": 0, "digest": None},
            {"id": 50, "name": "release.json", "state": "uploaded", "size": 1, "digest": None}]:
            api = FakeGitHub()
            api.ambiguous_create = True
            with self.assertRaises(release.Invalid):
                self.publish(api)
            api.extra_assets = [asset]
            api.calls.clear()
            with self.subTest(asset=asset), self.assertRaises(release.Invalid):
                self.publish(api)
            self.assertEqual(api.mutations(), [])

    def test_remote_content_failure_no_publish(self):
        self.seal()
        api = FakeGitHub()
        api.corrupt_download = True
        with self.assertRaises(release.Invalid):
            self.publish(api)
        self.assertTrue(api.release["draft"])
        self.assertFalse(any(c[0] == "PATCH" for c in api.calls))

    def test_archive_chained_link_escape_and_cycle_refused(self):
        def archive_with_links(links):
            stream = io.BytesIO(fixture_zip())
            with zipfile.ZipFile(stream, "a") as archive:
                for name, target in links:
                    entry = zipfile.ZipInfo("LessMeet.app/" + name)
                    entry.external_attr = 0o120777 << 16
                    archive.writestr(entry, target)
            return stream.getvalue()
        for links in [[("a", "."), ("b", "a/../outside")], [("a", "b"), ("b", "a")]]:
            with self.subTest(links=links), self.assertRaises(release.Invalid):
                release.validate_zip(archive_with_links(links))
        release.validate_zip(archive_with_links([
            ("Contents/Frameworks/F.framework/Versions/Current", "A"),
            ("Contents/Frameworks/F.framework/F", "Versions/Current/F")]))

    def test_archive_expansion_limit_refused(self):
        with patch.object(release, "MAX_ARCHIVE", 1), self.assertRaisesRegex(release.Invalid, "archive-expansion-limit"):
            release.validate_zip(fixture_zip())

    def test_both_conflict_statuses_reread_matching_bytes(self):
        self.seal()
        for operation in ("create_tag_race", "create_release_race", "upload_race"):
            for status in (409, 422):
                api = FakeGitHub()
                setattr(api, operation, "matching")
                api.race_status = status
                with self.subTest(operation=operation, status=status):
                    self.assertEqual(self.publish(api)["status"], "published")

    def test_ambiguous_tag_creation_recovers_without_retarget(self):
        self.seal()
        api = FakeGitHub()
        api.ambiguous_tag = True
        with self.assertRaises(release.Invalid):
            self.publish(api)
        self.assertIsNone(api.release)
        api.calls.clear()
        self.assertEqual(self.publish(api)["status"], "published")
        self.assertFalse(any(c[:2] == ("POST", "git/refs") for c in api.calls))

    def test_complete_remote_binding_and_hash_tamper_no_mutation(self):
        self.seal()
        good = FakeGitHub()
        self.publish(good)
        for target in ("manifest-binding", "archive", "changelog.md", "SHA256SUMS", "missing-asset"):
            api = copy.deepcopy(good)
            api.calls.clear()
            if target == "manifest-binding":
                value = release.decode(api.content["release.json"])
                value["pr_base_sha"] = "e" * 40
                api.content["release.json"] = release.encode(value)
            elif target == "archive":
                api.content[self.archive.name] += b"different-bytes"
            elif target == "missing-asset":
                del api.content["SHA256SUMS"]
            else:
                api.content[target] += b"different-bytes"
            with self.subTest(target=target), self.assertRaises(release.Invalid):
                self.publish(api)
            self.assertEqual(api.mutations(), [])

    def test_concurrent_complete_release_is_not_edited(self):
        self.seal()
        api = FakeGitHub()
        self.publish(api)
        api.release["draft"] = True
        api.calls.clear()
        original = api.json
        def finish_on_read(method, endpoint, payload=None):
            if method == "GET" and endpoint == "releases/41":
                api.release["draft"] = False
            return original(method, endpoint, payload)
        api.json = finish_on_read
        self.assertEqual(self.publish(api)["status"], "already-published")
        self.assertEqual(api.mutations(), [])


class PlanTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = Path(tempfile.mkdtemp(prefix="git-case-", dir=EVIDENCE))
        cls.checkout = cls.folder / "checkout"
        cls.checkout.mkdir()
        def git(*args):
            env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
                   "GIT_TERMINAL_PROMPT": "0", "GIT_AUTHOR_DATE": "2020-01-01T00:00:00Z",
                   "GIT_COMMITTER_DATE": "2020-01-01T00:00:00Z"}
            return subprocess.check_output(["git", "-c", "init.templateDir=", "-c", "core.hooksPath=" + os.devnull,
                                            "-c", "commit.gpgsign=false", *args], cwd=cls.checkout,
                                           env=env, stderr=subprocess.DEVNULL).decode().strip()
        cls.git = staticmethod(git)
        git("init", "--initial-branch=main")
        git("config", "user.name", "Synthetic Fixture")
        git("config", "user.email", "fixture@example.invalid")
        (cls.checkout / "fixture").write_text("base")
        git("add", "fixture")
        git("commit", "-m", "Synthetic base")
        cls.parent = git("rev-parse", "HEAD")
        git("checkout", "-b", "feature")
        (cls.checkout / "fixture").write_text("feature")
        git("commit", "-am", "Add transcript search")
        cls.head = git("rev-parse", "HEAD")
        git("checkout", "main")
        git("merge", "--no-ff", "feature", "-m", "SYNTHETIC-SECRET-MERGE-TITLE")
        cls.source = git("rev-parse", "HEAD")

    def event(self):
        return {"action": "closed", "number": 12, "repository": {"full_name": REPOSITORY},
                "pull_request": {"number": 12, "state": "closed", "merged": True, "merge_commit_sha": self.source,
                                 "title": "Add transcript search", "body": "SYNTHETIC-SECRET-PR-BODY", "commits": 1,
                                 "base": {"ref": "main", "repo": {"full_name": REPOSITORY}},
                                 "head": {"sha": self.head, "repo": {"full_name": "synthetic-fork/repo"}}}}

    def run_plan(self, event=None, event_name="pull_request_target", **kwargs):
        folder = Path(tempfile.mkdtemp(prefix="plan-", dir=EVIDENCE))
        source = folder / "event.json"
        source.write_bytes(release.encode(self.event() if event is None else event))
        before = Path.cwd()
        try:
            os.chdir(self.checkout)
            with patch.dict(os.environ, {"GITHUB_EVENT_NAME": event_name}):
                return release.plan(source, REPOSITORY, folder / "plan.json", folder / "github-output", **kwargs), folder
        finally:
            os.chdir(before)

    def test_exact_merge_fork_event_sequence_and_safe_provenance(self):
        value, folder = self.run_plan()
        self.assertEqual(value["source_sha"], self.source)
        self.assertEqual(value["sequence"], 2)
        self.assertIs(type(value["sequence"]), int)
        self.assertTrue(value["tag"].endswith(self.source))
        self.assertEqual(value["pr_base_sha"], self.parent)
        self.assertIn(self.head, value["commit_shas"])
        self.assertNotIn("SECRET", (folder / "plan.json").read_text())
        output = (folder / "github-output").read_text()
        self.assertEqual({line.split("=")[0] for line in output.splitlines()}, {"source_sha", "tag", "archive_name", "sequence"})

    def test_event_gates(self):
        cases = []
        for key, bad in [("action", "opened"), ("number", 13)]:
            event = self.event(); event[key] = bad; cases.append(event)
        for key, bad in [("merged", False), ("merged", "true"), ("state", "open"), ("merge_commit_sha", self.source.upper()),
                         ("merge_commit_sha", self.head), ("merge_commit_sha", "refs/heads/main"), ("number", True)]:
            event = self.event(); event["pull_request"][key] = bad; cases.append(event)
        event = self.event(); event["pull_request"]["base"]["ref"] = "other"; cases.append(event)
        event = self.event(); event["repository"]["full_name"] = "other/repo"; cases.append(event)
        event = self.event(); event["pull_request"]["base"]["repo"]["full_name"] = "other/repo"; cases.append(event)
        for event in cases:
            with self.subTest(event=event), self.assertRaises(release.Invalid):
                self.run_plan(event)

    def test_event_names(self):
        self.run_plan(event_name="pull_request")
        for name in ("push", "workflow_dispatch", "", "release"):
            with self.subTest(name=name), self.assertRaises(release.Invalid):
                self.run_plan(event_name=name)

    def test_main_first_parent_not_general_ancestry(self):
        real_git = release.git
        def fake(*args):
            if args == ("rev-list", "--first-parent", "refs/heads/main"):
                return self.parent
            return real_git(*args)
        with patch.object(release, "git", side_effect=fake), self.assertRaises(release.Invalid):
            self.run_plan()

    def test_matching_remote_accepts_stale_local_main(self):
        real_git = release.git
        calls = []
        def fake(*args):
            calls.append(args)
            if args == ("for-each-ref", "--format=%(refname)", "refs/remotes/origin/main"):
                return "refs/remotes/origin/main"
            if args == ("rev-list", "--first-parent", "refs/remotes/origin/main"):
                return self.source + "\n" + self.parent
            if args == ("rev-list", "--first-parent", "refs/heads/main"):
                return self.parent
            return real_git(*args)
        with patch.object(release, "git", side_effect=fake):
            value, _ = self.run_plan()
        self.assertEqual(value["source_sha"], self.source)
        self.assertFalse(any(args[-1] == "refs/heads/main" for args in calls))

    def test_absent_remote_falls_back_to_local_main(self):
        real_git = release.git
        calls = []
        def fake(*args):
            calls.append(args)
            if args == ("for-each-ref", "--format=%(refname)", "refs/remotes/origin/main"):
                return ""
            return real_git(*args)
        with patch.object(release, "git", side_effect=fake):
            value, _ = self.run_plan()
        self.assertEqual(value["source_sha"], self.source)
        self.assertIn(("rev-list", "--first-parent", "refs/heads/main"), calls)

    def test_neither_main_ref_fails_closed(self):
        real_git = release.git
        def fake(*args):
            if args[:2] == ("for-each-ref", "--format=%(refname)"):
                return ""
            return real_git(*args)
        with patch.object(release, "git", side_effect=fake), self.assertRaisesRegex(release.Invalid, "authoritative-main-ref-required"):
            self.run_plan()

    def test_remote_nonfirstparent_fails_even_if_local_matches(self):
        real_git = release.git
        calls = []
        def fake(*args):
            calls.append(args)
            if args == ("for-each-ref", "--format=%(refname)", "refs/remotes/origin/main"):
                return "refs/remotes/origin/main"
            if args == ("rev-list", "--first-parent", "refs/remotes/origin/main"):
                return self.parent
            return real_git(*args)
        with patch.object(release, "git", side_effect=fake), self.assertRaisesRegex(release.Invalid, "merge-not-on-main-first-parent"):
            self.run_plan()
        self.assertFalse(any(args[-1] == "refs/heads/main" for args in calls))

    def test_shallow_history_refused(self):
        real_git = release.git
        def fake(*args):
            return "true" if args == ("rev-parse", "--is-shallow-repository") else real_git(*args)
        with patch.object(release, "git", side_effect=fake), self.assertRaises(release.Invalid):
            self.run_plan()

    def test_sequence_advances_without_changing_earlier_plan(self):
        first, _ = self.run_plan()
        try:
            self.git("checkout", "-b", "later-feature")
            (self.checkout / "later").write_text("later synthetic change")
            self.git("add", "later")
            self.git("commit", "-m", "Later fixture")
            later_head = self.git("rev-parse", "HEAD")
            self.git("checkout", "main")
            self.git("merge", "--no-ff", "later-feature", "-m", "Later synthetic merge")
            later = self.git("rev-parse", "HEAD")
            event = self.event()
            event["pull_request"]["merge_commit_sha"] = later
            event["pull_request"]["head"]["sha"] = later_head
            second, _ = self.run_plan(event)
            self.assertEqual(second["sequence"], first["sequence"] + 1)
            self.assertEqual(first["source_sha"], self.source)
            self.assertNotEqual(second["tag"], first["tag"])
        finally:
            # Restore only this owned synthetic checkout, not the project checkout.
            self.git("checkout", "--detach", self.source)

    def test_github_output_symlink_refused(self):
        folder = Path(tempfile.mkdtemp(prefix="output-link-", dir=EVIDENCE))
        event = folder / "event.json"
        event.write_bytes(release.encode(self.event()))
        target = folder / "original"
        target.write_bytes(b"synthetic original")
        link = folder / "github-output"
        link.symlink_to(target)
        before = Path.cwd()
        try:
            os.chdir(self.checkout)
            with patch.dict(os.environ, {"GITHUB_EVENT_NAME": "pull_request_target"}), self.assertRaises(release.Invalid):
                release.plan(event, REPOSITORY, folder / "plan.json", link)
        finally:
            os.chdir(before)
        self.assertEqual(target.read_bytes(), b"synthetic original")


class Response:
    def __init__(self, request, data):
        self.url = request.full_url
        self.data = data
        self.status = 200
    def geturl(self): return self.url
    def read(self, limit): return self.data[:limit]
    def __enter__(self): return self
    def __exit__(self, *args): return False


class HTTPTests(unittest.TestCase):
    def fake(self, actions):
        class Opener:
            def __init__(self): self.requests = []
            def open(self, request, timeout):
                self.requests.append(request)
                action = actions[len(self.requests) - 1]
                if isinstance(action, Exception): raise action
                return Response(request, action)
        opener = Opener()
        return release.GitHub(REPOSITORY, "SYNTHETIC-TOKEN", opener), opener

    def redirect(self, location):
        return urllib.error.HTTPError("https://api.github.com/secret", 302, "SYNTHETIC-SECRET", {"Location": location}, None)

    def test_fixed_upload_host_version_and_no_server_upload_url(self):
        api, opener = self.fake([b'{}'])
        api.upload(41, "release.json", b'{}')
        request = opener.requests[0]
        self.assertEqual(request.full_url, "https://uploads.github.com/repos/synthetic/lessmeet/releases/41/assets?name=release.json")
        self.assertEqual(request.get_header("X-github-api-version"), "2026-03-10")
        self.assertEqual(request.get_header("Authorization"), "Bearer SYNTHETIC-TOKEN")
        self.assertIsNone(release.NoRedirect().redirect_request(request, None, 302, "", {}, "https://evil.invalid"))

    def test_redirect_strips_credentials_and_cookies(self):
        for host in ("release-assets.githubusercontent.com", "objects.githubusercontent.com:443"):
            api, opener = self.fake([self.redirect("https://" + host + "/asset?signature=SYNTHETIC-SECRET"), b"metadata"])
            self.assertEqual(api.download(1), b"metadata")
            self.assertEqual(opener.requests[0].get_header("Authorization"), "Bearer SYNTHETIC-TOKEN")
            self.assertIsNone(opener.requests[1].get_header("Authorization"))
            self.assertIsNone(opener.requests[1].get_header("Cookie"))
            self.assertIsNone(opener.requests[1].data)

    def test_hostile_redirect_refused_without_request(self):
        for location in ["https://evil.invalid/asset", "http://objects.githubusercontent.com/asset",
                         "https://objects.githubusercontent.com.evil.invalid/asset", "https://user@objects.githubusercontent.com/asset",
                         "https://user:pass@objects.githubusercontent.com/asset", "https://objects.githubusercontent.com:bad/asset",
                         "https://objects.githubusercontent.com:8443/asset", "//objects.githubusercontent.com/asset", "https://objects.githubusercontent.com/asset#fragment"]:
            api, opener = self.fake([self.redirect(location)])
            with self.subTest(location=location), self.assertRaises(release.Invalid):
                api.download(1)
            self.assertEqual(len(opener.requests), 1)

    def test_second_redirect_refused_and_secret_safe(self):
        api, opener = self.fake([self.redirect("https://objects.githubusercontent.com/a?secret=SYNTHETIC-SECRET"),
                                 self.redirect("https://evil.invalid/?secret=SYNTHETIC-SECRET")])
        with self.assertRaises(release.APIError) as caught:
            api.download(1)
        self.assertNotIn("SECRET", str(caught.exception))
        self.assertEqual(len(opener.requests), 2)

    def test_upload_redirect_refused_no_follow(self):
        api, opener = self.fake([self.redirect("https://objects.githubusercontent.com/asset")])
        with self.assertRaises(release.APIError):
            api.upload(41, "release.json", b'{}')
        self.assertEqual(len(opener.requests), 1)

    def test_api_body_header_transport_errors_never_exposed(self):
        for error in [urllib.error.HTTPError("https://secret.invalid", 500, "SYNTHETIC-SECRET", {"Secret": "SYNTHETIC-SECRET"}, io.BytesIO(b"SYNTHETIC-SECRET")),
                      urllib.error.URLError("SYNTHETIC-SECRET-TOKEN")]:
            api, _ = self.fake([error])
            with self.assertRaises(release.Invalid) as caught:
                api.json("GET", "releases")
            self.assertNotIn("SECRET", str(caught.exception))

    def test_cli_errors_are_secret_safe(self):
        stderr = io.StringIO()
        with patch.object(release, "publish", side_effect=ValueError("SYNTHETIC-SECRET")), patch("sys.stderr", stderr):
            status = release.main(["publish", "--directory", "/synthetic", "--expected-sha", SOURCE, "--repo", REPOSITORY])
        self.assertEqual(status, 1)
        self.assertNotIn("SECRET", stderr.getvalue())

    def test_metadata_limit_and_redirected_transport_failure(self):
        api, _ = self.fake([b"x" * (release.MAX_METADATA + 1)])
        with self.assertRaisesRegex(release.Invalid, "github-metadata-too-large"):
            api.download(1)
        api, opener = self.fake([self.redirect("https://objects.githubusercontent.com/asset?signature=SYNTHETIC-SECRET"),
                                 urllib.error.URLError("SYNTHETIC-SECRET-SIGNED-URL")])
        with self.assertRaises(release.Invalid) as caught:
            api.download(1)
        self.assertNotIn("SECRET", str(caught.exception))
        self.assertEqual(len(opener.requests), 2)

    def test_fixed_paginated_endpoints_ignore_server_links(self):
        api, opener = self.fake([json.dumps([{"id": i} for i in range(100)]).encode(), b'[]'])
        self.assertEqual(len(release.pages(api, "releases")), 100)
        self.assertEqual([r.full_url for r in opener.requests], [
            "https://api.github.com/repos/synthetic/lessmeet/releases?per_page=100&page=1",
            "https://api.github.com/repos/synthetic/lessmeet/releases?per_page=100&page=2"])


if __name__ == "__main__":
    unittest.main()
