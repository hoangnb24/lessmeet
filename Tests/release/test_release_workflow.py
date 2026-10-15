"""Offline policy checks for the exact merged-main workflow, using Ruby's YAML parser."""

import json
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/main-release.yml"


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parsed = subprocess.run(
            ["ruby", "-rjson", "-ryaml", "-e", "puts JSON.generate(YAML.safe_load(File.read(ARGV.fetch(0))))", str(WORKFLOW)],
            capture_output=True, text=True, check=True,
        )
        cls.workflow = json.loads(parsed.stdout)
        cls.build = cls.workflow["jobs"]["build"]
        cls.publish = cls.workflow["jobs"]["publish"]

    def test_only_closed_target_main_events(self):
        # YAML 1.1 parsers represent unquoted 'on' as Boolean true.
        event = self.workflow.get("on", self.workflow.get("true"))
        self.assertEqual(event, {"pull_request_target": {"types": ["closed"], "branches": ["main"]}})
        guard = self.build["if"]
        for fragment in ("github.event.action == 'closed'", "github.event.pull_request.merged == true",
                         "github.event.pull_request.base.ref == 'main'",
                         "github.event.pull_request.base.repo.full_name == github.repository",
                         "github.repository == 'hoangnb24/lessmeet'"):
            self.assertIn(fragment, guard)

    def test_exact_sha_no_unmerged_code(self):
        first = self.build["steps"][0]
        self.assertNotIn("ref", first["with"])
        self.assertEqual(first["with"]["fetch-depth"], 0)
        second = self.publish["steps"][0]
        self.assertNotIn("ref", second["with"])
        self.assertEqual(second["with"]["fetch-depth"], 0)
        self.assertEqual(self.build["steps"][1]["env"]["MERGE_SHA"], "${{ github.event.pull_request.merge_commit_sha }}")
        self.assertEqual(self.publish["steps"][1]["env"]["MERGE_SHA"], "${{ needs.build.outputs.source_sha }}")
        for job in (self.build, self.publish):
            select = job["steps"][1]["run"]
            self.assertIn('[[ "$MERGE_SHA" =~ ^[0-9a-f]{40}$ ]]', select)
            self.assertIn('git merge-base --is-ancestor "$MERGE_SHA" refs/remotes/origin/main', select)
            self.assertIn('git checkout --detach "$MERGE_SHA"', select)
            self.assertIn('test "$(git rev-parse HEAD)" = "$MERGE_SHA"', select)
            self.assertLess(select.index("--is-ancestor"), select.index("checkout --detach"))
        for job in (self.build, self.publish):
            for step in job["steps"]:
                self.assertNotIn("pull_request.head", json.dumps(step))
                self.assertNotIn("refs/pull/", json.dumps(step))
                if step.get("uses", "").startswith("actions/checkout@"):
                    self.assertIs(step["with"]["persist-credentials"], False)
                    self.assertNotIn("allow-unsafe-pr-checkout", step["with"])

    def test_minimal_permissions_and_step_scoped_apple_secrets(self):
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        self.assertEqual(self.build["permissions"], {"contents": "read"})
        self.assertEqual(self.publish["permissions"], {"contents": "write"})
        secret_steps = [s for s in self.build["steps"] if "secrets." in json.dumps(s)]
        self.assertEqual(len(secret_steps), 1)
        self.assertIn("ci-sign-release.py --execute", secret_steps[0]["run"])
        self.assertEqual(len(secret_steps[0]["env"]), 7)
        self.assertEqual(self.build["environment"], "lessmeet-developer-id")
        self.assertIn("vars.LESSMEET_DEVELOPER_ID_RELEASE_ENABLED == 'true'", self.build["if"])
        for name in ("ASC_", "TESTFLIGHT", "fastlane", "altool"):
            self.assertNotIn(name, WORKFLOW.read_text())
        token_steps = [step for job in (self.build, self.publish) for step in job["steps"]
                       if "GH_TOKEN" in step.get("env", {})]
        self.assertEqual(len(token_steps), 1)
        self.assertEqual(token_steps[0], self.publish["steps"][-1])
        read_steps = [step for job in (self.build, self.publish) for step in job["steps"]
                      if "GH_READ_TOKEN" in step.get("env", {})]
        self.assertEqual(len(read_steps), 1)
        self.assertEqual(read_steps[0]["id"], "plan")
        self.assertIn("--fetch-pr-head", read_steps[0]["run"])

    def test_failure_cannot_publish_and_activation_is_explicit(self):
        self.assertEqual(self.publish["needs"], "build")
        self.assertIn("needs.build.result == 'success'", self.publish["if"])
        self.assertIn("vars.LESSMEET_GITHUB_RELEASE_ENABLED == 'true'", self.publish["if"])
        for job in (self.build, self.publish):
            self.assertNotIn("continue-on-error", job)
            self.assertNotIn("always()", job.get("if", ""))
            for step in job["steps"]:
                self.assertNotIn("continue-on-error", step)
                if "always()" in step.get("if", ""):
                    self.assertEqual(step["run"], "python3 scripts/ci-sign-release.py --cleanup")
                    self.assertNotIn("env", step)
        build_steps = [step.get("run", "") for step in self.build["steps"]]
        self.assertTrue(any("unittest discover -s Tests/release" in step for step in build_steps))
        self.assertTrue(any("unittest discover -s Tests/packaging" in step for step in build_steps))
        self.assertTrue(any("build-github-release.py" in step and "--execute" in step for step in build_steps))

    def test_concurrent_merges_cannot_cancel_or_replace_each_other(self):
        concurrency = self.workflow["concurrency"]
        self.assertIn("github.event.pull_request.merge_commit_sha", concurrency["group"])
        self.assertIs(concurrency["cancel-in-progress"], False)
        upload = next(step for step in self.build["steps"] if step.get("id") == "upload")
        self.assertIs(upload["with"]["overwrite"], False)
        for value in ("source_sha", "github.run_id", "github.run_attempt"):
            self.assertIn(value, upload["with"]["name"])

    def test_failed_publish_rerun_uses_exact_build_artifact(self):
        self.assertEqual(self.build["outputs"]["artifact_id"], "${{ steps.upload.outputs.artifact-id }}")
        download = next(step for step in self.publish["steps"] if step.get("uses", "").startswith("actions/download-artifact@"))
        self.assertEqual(download["with"]["artifact-ids"], "${{ needs.build.outputs.artifact_id }}")
        self.assertNotIn("name", download["with"])
        self.assertNotIn("pattern", download["with"])
        self.assertNotIn("run-id", download["with"])
        self.assertEqual(download["with"]["digest-mismatch"], "error")
        self.assertTrue(self.publish["steps"][-2]["run"].strip().endswith('--repo "$GITHUB_REPOSITORY"'))

    def test_artifact_allowlist_excludes_logs_and_private_data(self):
        upload = next(step for step in self.build["steps"] if step.get("id") == "upload")
        paths = upload["with"]["path"].splitlines()
        self.assertEqual(paths, [
            "release-assets/${{ steps.plan.outputs.archive_name }}", "release-assets/release.json",
            "release-assets/changelog.md", "release-assets/SHA256SUMS",
        ])
        self.assertIs(upload["with"]["include-hidden-files"], False)
        self.assertEqual(upload["with"]["if-no-files-found"], "error")

    def test_actions_pinned_and_untrusted_text_not_shell_interpolated(self):
        for job in (self.build, self.publish):
            for step in job["steps"]:
                if "uses" in step:
                    self.assertRegex(step["uses"], r"^[a-zA-Z0-9_/-]+@[0-9a-f]{40}$")
                self.assertNotIn("${{", step.get("run", ""))


if __name__ == "__main__":
    unittest.main()
