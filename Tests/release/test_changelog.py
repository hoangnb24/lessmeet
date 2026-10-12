"""Offline Git graphs emulate documented merge modes; no hosted claims or fetch."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("changelog_release", ROOT / "scripts/github-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
EVIDENCE = ROOT / ".artifacts/release-automation/changelog-reopen/tests"
EVIDENCE.mkdir(parents=True, exist_ok=True)
REPO = "synthetic/lessmeet"


class ChangelogTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp(prefix="graph-", dir=EVIDENCE))
        self.repo = self.folder / "checkout"
        self.repo.mkdir()
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", "Synthetic Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        (self.repo / "base").write_text("base\n")
        self.git("add", "base")
        self.git("commit", "-m", "Synthetic base")
        self.base = self.git("rev-parse", "HEAD")
        self.git("checkout", "-b", "feature")
        (self.repo / "transcript").write_text("search\n")
        self.git("add", "transcript")
        self.git("commit", "-m", "Add transcript search")
        self.first = self.git("rev-parse", "HEAD")
        self.git("commit", "--allow-empty", "-m", "Record empty checkpoint")
        self.empty = self.git("rev-parse", "HEAD")
        (self.repo / "transcript").write_text("search\nselection\n")
        self.git("commit", "-am", "Preserve selected transcript")
        self.head = self.git("rev-parse", "HEAD")
        self.git("checkout", "main")
        (self.repo / "unrelated").write_text("not from the PR\n")
        self.git("add", "unrelated")
        self.git("commit", "-m", "Unrelated main change")
        self.before = self.git("rev-parse", "HEAD")

    def git(self, *args):
        env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
               "GIT_TERMINAL_PROMPT": "0", "GIT_AUTHOR_DATE": "2020-01-01T00:00:00Z",
               "GIT_COMMITTER_DATE": "2020-01-01T00:00:00Z"}
        return subprocess.check_output(["git", "-c", "init.templateDir=", "-c", "core.hooksPath=" + os.devnull,
                                        "-c", "commit.gpgsign=false", *args], cwd=self.repo, env=env,
                                       stderr=subprocess.DEVNULL).decode().strip()

    def integrate(self, mode):
        if mode == "merge":
            self.git("merge", "--no-ff", "feature", "-m", "Merge transcript improvements")
        elif mode == "squash":
            self.git("merge", "--squash", "feature")
            self.git("commit", "-m", "Add transcript search and preserve selection")
        else:
            # GitHub documents new SHAs and dropping originally-empty commits.
            # Replay nonempty commits on newer main to reproduce that graph.
            self.git("cherry-pick", self.first)
            self.git("cherry-pick", self.head)
        self.source = self.git("rev-parse", "HEAD")
        self.event = {"action": "closed", "number": 27, "repository": {"full_name": REPO},
                      "pull_request": {"number": 27, "state": "closed", "merged": True,
                          "merge_commit_sha": self.source, "commits": 3,
                          "title": "Add transcript search and preserve selection", "body": "DO-NOT-COPY-BODY",
                          "head": {"sha": self.head},
                          # Deliberately postmerge. The algorithm must not assume premerge timing.
                          "base": {"ref": "main", "sha": self.source, "repo": {"full_name": REPO}}}}
        self.event_file = self.folder / "event.json"

    def plan(self):
        self.event_file.write_bytes(release.encode(self.event))
        previous = Path.cwd()
        try:
            os.chdir(self.repo)
            with patch.dict(os.environ, {"GITHUB_EVENT_NAME": "pull_request_target"}):
                return release.plan(self.event_file, REPO, self.folder / "plan.json")
        finally:
            os.chdir(previous)

    def check_coverage(self, mode):
        self.integrate(mode)
        value = self.plan()
        self.assertEqual(value["commit_shas"], [self.first, self.empty, self.head])
        self.assertEqual(value["commit_subjects"], ["Add transcript search", "Record empty checkpoint", "Preserve selected transcript"])
        self.assertNotIn(self.before, value["commit_shas"])
        self.assertNotIn(self.source, value["commit_shas"])
        self.assertEqual(value["pr_base_sha"], self.base)
        self.assertEqual(value["integration_boundary_sha"], self.before if mode == "merge" else self.source)
        self.assertEqual(value["integration_shape"], "merge-commit" if mode == "merge" else "linear")
        notes = release.changelog(value).decode()
        for subject in value["commit_subjects"]:
            self.assertIn(subject, notes)
        self.assertIn("Original PR commits (3)", notes)
        self.assertIn("Add transcript search and preserve selection", notes)
        self.assertIn("/compare/" + self.base + "..." + self.head, notes)
        self.assertNotIn("/compare/" + self.before + "..." + self.source, notes)
        self.assertNotIn("DO-NOT-COPY-BODY", notes)
        (self.folder / "changelog.md").write_text(notes)
        (self.folder / "mode.json").write_text(json.dumps({"fixture_mode": mode, "source": self.source,
                                                         "original": value["commit_shas"]}, indent=2))
        return value

    def test_merge_commit_covers_all_original_commits(self):
        self.check_coverage("merge")

    def test_squash_covers_all_original_commits(self):
        self.check_coverage("squash")

    def test_rebase_covers_all_commits_including_dropped_empty(self):
        value = self.check_coverage("rebase")
        rewritten = self.git("rev-list", "--reverse", self.before + ".." + self.source).splitlines()
        self.assertEqual(len(rewritten), 2)
        self.assertTrue(set(rewritten).isdisjoint(value["commit_shas"]))
        self.assertEqual(self.git("rev-list", self.source + "^1.." + self.source), self.source)

    def test_unchanged_event_and_body_edit_keep_identical_snapshot(self):
        self.integrate("rebase")
        first = self.plan()
        self.event["pull_request"]["body"] = "Edited after publish @everyone <script>"
        self.event["pull_request"]["base"]["sha"] = "0" * 40
        self.assertEqual(release.encode(self.plan()), release.encode(first))
        self.event["pull_request"]["title"] = "Changed title in a different event"
        with self.assertRaisesRegex(release.Invalid, "existing-plan-mismatch"):
            self.plan()
        self.assertEqual((self.folder / "plan.json").read_bytes(), release.encode(first))

    def test_count_mismatch_never_outputs_partial_notes(self):
        self.integrate("rebase")
        for count in (1, 2, 4, True, 0, 2049):
            self.event["pull_request"]["commits"] = count
            with self.subTest(count=count), self.assertRaises(release.Invalid):
                self.plan()
        self.assertFalse((self.folder / "plan.json").exists())

    def test_merge_parent_mismatch_fails(self):
        self.integrate("merge")
        self.event["pull_request"]["head"]["sha"] = self.first
        with self.assertRaisesRegex(release.Invalid, "merge-second-parent"):
            self.plan()

    def test_missing_head_is_offline_failure(self):
        self.integrate("squash")
        self.event["pull_request"]["head"]["sha"] = "f" * 40
        with self.assertRaisesRegex(release.Invalid, "pr-head-unavailable"):
            self.plan()

    def test_multiple_merge_bases_fail(self):
        self.integrate("rebase")
        original = release.git
        def git(*args, **kwargs):
            return self.base + "\n" + self.before if args[:2] == ("merge-base", "--all") else original(*args, **kwargs)
        with patch.object(release, "git", side_effect=git), self.assertRaisesRegex(release.Invalid, "ambiguous-pr-merge-base"):
            self.plan()

    def test_graft_and_missing_ancestor_fail_closed(self):
        self.integrate("merge")
        original = release.git
        def grafted(*args, **kwargs):
            return str(self.repo / "base") if args == ("rev-parse", "--git-path", "info/grafts") else original(*args, **kwargs)
        with patch.object(release, "git", side_effect=grafted), self.assertRaisesRegex(release.Invalid, "grafted-history"):
            self.plan()
        def missing(*args, **kwargs):
            if args[:2] == ("rev-list", "--parents"):
                raise release.Invalid("git-history-check-failed")
            return original(*args, **kwargs)
        with patch.object(release, "git", side_effect=missing), self.assertRaisesRegex(release.Invalid, "history-check"):
            self.plan()


class TextAndFetchTests(unittest.TestCase):
    def test_untrusted_text_is_single_inert_span(self):
        for text in ["Fix `<img src=x onerror=alert(1)>` @team", "[click](javascript:alert(1)) ![x](https://evil.invalid)",
                     "``` <script>evil</script> `` @owner/repo #123", "line\n## heading\r\n- injected", "Lưu café e\u0301\u202e\x00"]:
            canonical = release.canonical_text(text)
            rendered = release.inert_text(canonical)
            fence = rendered[:len(rendered) - len(rendered.lstrip("`"))]
            self.assertTrue(rendered.endswith(" " + fence))
            inner = rendered[len(fence) + 1:-len(fence) - 1]
            self.assertNotIn(fence, inner)
            self.assertNotIn("@", inner)
            self.assertNotIn("\n", inner)
            self.assertNotIn("\r", inner)
            self.assertNotIn("\u202e", inner)
            self.assertEqual(release.canonical_text(canonical), canonical)

    def test_empty_oversized_and_invalid_text_rejected(self):
        for text in (None, 17, "\r\n\x00", "x" * 1001, "\ud800"):
            with self.subTest(text=repr(text)), self.assertRaises(release.Invalid):
                release.canonical_text(text)

    def test_fetch_fixed_repo_read_token_only_data_and_no_checkout(self):
        head = "a" * 40
        with patch.dict(os.environ, {"GH_READ_TOKEN": "synthetic-read-token"}), \
             patch.object(release, "git", side_effect=[release.Invalid("missing"), "", head, head]) as git:
            release.ensure_pr_head(REPO, 27, head, True)
        fetch = git.call_args_list[1]
        self.assertEqual(fetch.args, ("fetch", "--no-tags", "--no-recurse-submodules", "--refmap=",
                                    "https://github.com/synthetic/lessmeet.git", "refs/pull/27/head"))
        self.assertNotIn("synthetic-read-token", str(fetch.args))
        environment = fetch.kwargs["environment"]
        settings = {environment["GIT_CONFIG_KEY_" + str(i)]: environment["GIT_CONFIG_VALUE_" + str(i)]
                    for i in range(int(environment["GIT_CONFIG_COUNT"]))}
        self.assertEqual(settings["http.followRedirects"], "false")
        self.assertEqual(settings["credential.helper"], "")
        self.assertTrue(settings["http.https://github.com/.extraheader"].startswith("AUTHORIZATION: basic "))
        self.assertFalse(any(call.args[0] == "checkout" for call in git.call_args_list))

    def test_fetch_moved_tip_and_transport_failure_refused(self):
        head = "a" * 40
        with patch.object(release, "git", side_effect=[release.Invalid("missing"), "", "b" * 40]):
            with self.assertRaisesRegex(release.Invalid, "fetched-pr-head-moved"):
                release.ensure_pr_head(REPO, 27, head, True)
        with patch.object(release.subprocess, "run", side_effect=OSError("secret-token")):
            with self.assertRaises(release.Invalid) as caught:
                release.ensure_pr_head(REPO, 27, head, True)
        self.assertNotIn("secret-token", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
