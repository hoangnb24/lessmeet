#!/usr/bin/env python3
"""Deterministic diagnostic GitHub releases. Execute is opt-in; never clobber.

REST contract verified against GitHub's releases, assets and Git refs docs.
API version: 2026-03-10. Uploads use the fixed uploads.github.com endpoint.
No gh, pip, cloud SDK, Apple version change, build or live readiness assertion.
"""
import argparse
import base64
import hashlib
import heapq
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import zipfile

API_VERSION = "2026-03-10"
READINESS = "diagnostic; build/package only; runtime/auth/inference unverified"
SHA = re.compile(r"[0-9a-f]{40}\Z")
HASH = re.compile(r"[0-9a-f]{64}\Z")
REPO = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,99}/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}\Z")
MAX_ARCHIVE = 2 * 1024 * 1024 * 1024 - 1
MAX_METADATA = 2 * 1024 * 1024
PLAN_KEYS = {"schema", "source_sha", "sequence", "tag", "archive_name", "repository",
             "pr_number", "pr_title", "pr_head_sha", "pr_base_sha", "pr_commit_count",
             "commit_shas", "commit_subjects", "integration_shape", "coverage",
             "integration_boundary_sha",
             "pr_url", "compare_url", "readiness"}
RECOVERY = "draft-bytes-mismatch: rerun the failed publish job retaining the original build artifact; never rebuild, overwrite or delete"


class Invalid(Exception):
    """Messages are fixed local identifiers, never server/file/credential text."""


class APIError(Invalid):
    def __init__(self, status):
        self.status = status
        super().__init__("github-api-status-" + str(status))


def require(condition, code):
    if not condition:
        raise Invalid(code)


def integer(value):
    return type(value) is int and value > 0


def repository(value):
    require(isinstance(value, str) and REPO.fullmatch(value), "invalid-repository")
    return value.lower()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encode(value):
    return (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=True) + "\n").encode()


def decode(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate-json-key")
            result[key] = value
        return result
    try:
        return json.loads(data, object_pairs_hook=unique,
                          parse_constant=lambda _: (_ for _ in ()).throw(Invalid("invalid-json-number")))
    except (ValueError, UnicodeError):
        raise Invalid("invalid-json") from None


def path_without_links(path):
    path = Path(os.path.abspath(path))
    for component in (path, *path.parents):
        require(not component.is_symlink(), "symlink-input-or-output")
    return path


def read(path, limit):
    path = path_without_links(path)
    try:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
        with os.fdopen(os.open(path, flags), "rb") as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_size <= limit, "invalid-file-size-or-type")
            data = stream.read(limit + 1)
            require(len(data) <= limit and len(data) == info.st_size, "file-changed-or-too-large")
            return data
    except OSError:
        raise Invalid("file-read-failed") from None


def write_new(path, data):
    path = path_without_links(path)
    try:
        with path.open("xb") as stream:
            stream.write(data)
    except OSError:
        raise Invalid("output-exists-or-write-failed") from None


def git(*args, environment=None, timeout=30):
    try:
        process = subprocess.run(["git", "--no-replace-objects", *args], capture_output=True, timeout=timeout,
                                 env={**os.environ, "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C", **(environment or {})})
        require(process.returncode == 0, "git-history-check-failed")
        return process.stdout.decode("utf-8").strip()
    except (OSError, UnicodeError, subprocess.TimeoutExpired):
        raise Invalid("git-history-check-failed") from None


def canonical_text(value):
    require(isinstance(value, str) and len(value) <= 1000, "invalid-changelog-text")
    # Flatten lines and remove control/bidi characters. Never truncate a subject.
    value = unicodedata.normalize("NFC", value)
    value = "".join(" " if unicodedata.category(c).startswith("C") else c for c in value)
    value = " ".join(value.split())
    require(bool(value), "empty-changelog-text")
    return value


def inert_text(value):
    # GFM code spans treat HTML, links and Markdown as text. A longer delimiter
    # prevents embedded backticks from closing the span. Neutralize @ as well.
    value = value.replace("@", "＠")
    fence = "`" * (1 + max((len(m) for m in re.findall(r"`+", value)), default=0))
    return fence + " " + value + " " + fence


def ensure_pr_head(repo, number, head, fetch_head):
    try:
        require(git("rev-parse", "--verify", head + "^{commit}") == head, "invalid-pr-head-object")
        return
    except Invalid:
        require(fetch_head, "pr-head-unavailable: fetch captured PR history; never infer a partial range")
    token = os.environ.get("GH_READ_TOKEN", "")
    require(not token or all(33 <= ord(c) <= 126 for c in token), "invalid-read-token")
    settings = [("credential.helper", ""), ("http.followRedirects", "false"),
                ("core.hooksPath", os.devnull), ("maintenance.auto", "false"), ("gc.auto", "0")]
    if token:
        auth = base64.b64encode(("x-access-token:" + token).encode()).decode()
        settings.append(("http.https://github.com/.extraheader", "AUTHORIZATION: basic " + auth))
    environment = {"GIT_CONFIG_COUNT": str(len(settings)), "GIT_TRACE": "0", "GIT_TRACE_CURL": "0",
                   "GIT_CURL_VERBOSE": "0", "GIT_TRACE_PACKET": "0", "GIT_TRACE2": "0",
                   "GIT_TRACE2_EVENT": "0", "GIT_TRACE2_PERF": "0",
                   "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
    for index, (key, value) in enumerate(settings):
        environment["GIT_CONFIG_KEY_" + str(index)] = key
        environment["GIT_CONFIG_VALUE_" + str(index)] = value
    # Read objects only. Never check out or execute the PR head. No branch ref is
    # updated; FETCH_HEAD must still match the immutable event after the fetch.
    git("fetch", "--no-tags", "--no-recurse-submodules", "--refmap=",
        "https://github.com/" + repo + ".git", "refs/pull/{}/head".format(number),
        environment=environment, timeout=120)
    require(git("rev-parse", "--verify", "FETCH_HEAD") == head, "fetched-pr-head-moved")
    require(git("rev-parse", "--verify", head + "^{commit}") == head, "invalid-pr-head-object")


def pr_provenance(pr, repo, number, source, fetch_head):
    head = pr.get("head", {}).get("sha") if isinstance(pr.get("head"), dict) else None
    require(isinstance(head, str) and SHA.fullmatch(head), "invalid-pr-head")
    count = pr.get("commits")
    require(integer(count) and count <= 2048, "invalid-pr-commit-count")
    title = canonical_text(pr.get("title"))
    ensure_pr_head(repo, number, head, fetch_head)
    require(not Path(git("rev-parse", "--git-path", "info/grafts")).exists(), "grafted-history-not-supported")
    require(git("rev-parse", "--verify", "HEAD") == source, "checkout-changed-during-provenance")
    parents = git("show", "-s", "--no-show-signature", "--format=%P", source).split()
    require(len(parents) in (1, 2), "unsupported-integration-topology")
    if len(parents) == 2:
        require(parents[1] == head, "merge-second-parent-not-pr-head")
        boundary, shape = parents[0], "merge-commit"
    else:
        boundary, shape = source, "linear"
    records = [line.split() for line in git("rev-list", "--parents", boundary + ".." + head).splitlines()]
    require(len(records) == count, "pr-coverage-count-mismatch")
    parents_by_sha = {row[0]: set(row[1:]) for row in records}
    require(len(parents_by_sha) == count and head in parents_by_sha, "invalid-pr-history")
    # Stable topological order: a SHA tie-break avoids timestamp/order drift.
    pending = {sha: parents & parents_by_sha.keys() for sha, parents in parents_by_sha.items()}
    ready = [sha for sha, parents in pending.items() if not parents]
    heapq.heapify(ready)
    commits = []
    while ready:
        sha = heapq.heappop(ready)
        commits.append(sha)
        for child, parents in pending.items():
            if sha in parents:
                parents.remove(sha)
                if not parents:
                    heapq.heappush(ready, child)
    require(len(commits) == count and commits[-1] == head, "invalid-pr-history")
    bases = git("merge-base", "--all", boundary, head).splitlines()
    require(len(bases) == 1, "ambiguous-pr-merge-base")
    base = bases[0]
    # The immutable compare link must cover the same set, including empty commits.
    require(set(git("rev-list", base + ".." + head).splitlines()) == set(commits),
            "ambiguous-pr-compare-range")
    subjects = [canonical_text(git("show", "-s", "--no-show-signature", "--encoding=UTF-8", "--format=%s", sha))
                for sha in commits]
    return {"pr_title": title, "pr_head_sha": head, "pr_base_sha": base, "pr_commit_count": count,
            "commit_shas": commits, "commit_subjects": subjects, "integration_shape": shape,
            "integration_boundary_sha": boundary,
            "coverage": "original-pr-commits"}


def validate_plan(plan):
    require(isinstance(plan, dict) and set(plan) == PLAN_KEYS, "invalid-plan-schema")
    require(type(plan["schema"]) is int and plan["schema"] == 2, "invalid-plan-schema")
    require(isinstance(plan["source_sha"], str) and SHA.fullmatch(plan["source_sha"]), "invalid-source-sha")
    for field in ("pr_head_sha", "pr_base_sha", "integration_boundary_sha"):
        require(isinstance(plan[field], str) and SHA.fullmatch(plan[field]), "invalid-pr-provenance-sha")
    require(integer(plan["sequence"]) and integer(plan["pr_number"]), "invalid-sequence-or-pr")
    repo = repository(plan["repository"])
    require(plan["repository"] == repo, "noncanonical-repository")
    tag = "main-build-{}-{}".format(plan["sequence"], plan["source_sha"])
    require(plan["tag"] == tag and plan["archive_name"] == "LessMeet-" + tag + "-macos-arm64-adhoc.zip", "invalid-derived-names")
    commits = plan["commit_shas"]
    require(isinstance(commits, list) and 0 < len(commits) <= 2048
            and all(isinstance(c, str) and SHA.fullmatch(c) for c in commits)
            and len(set(commits)) == len(commits) and commits[-1] == plan["pr_head_sha"]
            and integer(plan["pr_commit_count"]) and len(commits) == plan["pr_commit_count"], "invalid-commit-provenance")
    require(plan["coverage"] == "original-pr-commits" and plan["integration_shape"] in ("merge-commit", "linear"),
            "invalid-coverage-policy")
    require(plan["pr_head_sha"] != plan["pr_base_sha"] and
            ((plan["integration_boundary_sha"] == plan["source_sha"]) == (plan["integration_shape"] == "linear")),
            "invalid-integration-boundary")
    require(canonical_text(plan["pr_title"]) == plan["pr_title"], "noncanonical-pr-title")
    subjects = plan["commit_subjects"]
    require(isinstance(subjects, list) and len(subjects) == len(commits)
            and all(canonical_text(s) == s for s in subjects), "invalid-commit-subjects")
    require(plan["pr_url"] == "https://github.com/{}/pull/{}".format(repo, plan["pr_number"])
            and plan["compare_url"] == "https://github.com/{}/compare/{}...{}".format(repo, plan["pr_base_sha"], plan["pr_head_sha"])
            and plan["readiness"] == READINESS, "invalid-provenance-or-readiness")
    require(len(encode(plan)) <= MAX_METADATA // 2, "provenance-snapshot-too-large")
    return plan


def plan(event_path, repo, output, github_output=None, fetch_head=False):
    repo = repository(repo)
    event_name = os.environ.get("GITHUB_EVENT_NAME")
    require(event_name is None or event_name in ("pull_request_target", "pull_request"), "unsupported-event-name")
    event = decode(read(event_path, MAX_METADATA))
    require(isinstance(event, dict), "invalid-event")
    pr = event.get("pull_request")
    require(isinstance(pr, dict) and event.get("action") == "closed" and pr.get("merged") is True
            and pr.get("state") == "closed", "event-not-closed-merged-pr")
    base = pr.get("base")
    require(isinstance(base, dict) and base.get("ref") == "main", "event-not-main")
    for record in (event.get("repository"), base.get("repo")):
        require(isinstance(record, dict) and isinstance(record.get("full_name"), str)
                and record["full_name"].lower() == repo, "event-repository-mismatch")
    number = pr.get("number")
    require(integer(number) and integer(event.get("number")) and event["number"] == number,
            "event-pr-number-mismatch")
    sha = pr.get("merge_commit_sha")
    require(isinstance(sha, str) and SHA.fullmatch(sha), "invalid-merge-sha")
    require(git("rev-parse", "--verify", "HEAD") == sha, "checkout-not-exact-merge-sha")
    require(git("rev-parse", "--is-shallow-repository") == "false", "full-history-required")
    main_ref = None
    for ref in ("refs/remotes/origin/main", "refs/heads/main"):
        if ref in git("for-each-ref", "--format=%(refname)", ref).splitlines():
            main_ref = ref
            break
    require(main_ref is not None, "authoritative-main-ref-required")
    require(sha in git("rev-list", "--first-parent", main_ref).splitlines(), "merge-not-on-main-first-parent")
    provenance = pr_provenance(pr, repo, number, sha, fetch_head)
    sequence = int(git("rev-list", "--first-parent", "--count", sha))
    tag = "main-build-{}-{}".format(sequence, sha)
    value = validate_plan({"schema": 2, "source_sha": sha, "sequence": sequence, "tag": tag,
                           "archive_name": "LessMeet-" + tag + "-macos-arm64-adhoc.zip", "repository": repo,
                           "pr_number": number, **provenance,
                           "pr_url": "https://github.com/{}/pull/{}".format(repo, number),
                           "compare_url": "https://github.com/{}/compare/{}...{}".format(repo, provenance["pr_base_sha"], provenance["pr_head_sha"]),
                           "readiness": READINESS})
    payload = encode(value)
    dest = path_without_links(output)
    if dest.exists():
        require(read(dest, MAX_METADATA) == payload, "existing-plan-mismatch")
    else:
        write_new(dest, payload)
    if github_output:
        dest = path_without_links(github_output)
        require(not dest.exists() or dest.is_file(), "invalid-github-output")
        flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
        with os.fdopen(os.open(dest, flags, 0o600), "w") as stream:
            for key in ("source_sha", "tag", "archive_name", "sequence"):
                stream.write("{}={}\n".format(key, value[key]))
    return value


def changelog(plan):
    lines = ["# " + plan["tag"], "", "Diagnostic macOS arm64 ad-hoc build. Not notarized.",
             "Runtime, authentication and inference are not verified by this release.", "",
             "Merged PR: [#{}]({}) — {}".format(plan["pr_number"], plan["pr_url"], inert_text(plan["pr_title"])),
             "Original PR changes: [compare captured base and head]({})".format(plan["compare_url"]),
             "Integration tip on main: [{}](https://github.com/{}/commit/{})".format(
                 plan["source_sha"], plan["repository"], plan["source_sha"]), "",
             "## Original PR commits ({})".format(plan["pr_commit_count"]), "",
             "All original PR commits are listed, including empty commits. These are not a rewritten-main range.",
             "Squash combines commits; rebase rewrites SHAs and may drop empty commits. The integration tip alone is not the full PR diff.", ""]
    lines.extend("- {} ([{}](https://github.com/{}/commit/{}))".format(inert_text(subject), sha[:12], plan["repository"], sha)
                 for sha, subject in zip(plan["commit_shas"], plan["commit_subjects"]))
    return ("\n".join(lines) + "\n").encode()


def validate_zip(data):
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            names = set()
            links = {}
            entries = archive.infolist()
            require(len(entries) <= 100000 and sum(e.file_size for e in entries) <= MAX_ARCHIVE,
                    "archive-expansion-limit")
            for entry in entries:
                name = entry.filename
                pieces = name.rstrip("/").split("/")
                require(name and "\\" not in name and not name.startswith("/")
                        and all(p not in ("", ".", "..") for p in pieces)
                        and pieces[0] == "LessMeet.app" and all(ord(c) >= 32 for c in name), "archive-path-not-allowed")
                require(name.rstrip("/").casefold() not in names, "duplicate-archive-path")
                names.add(name.rstrip("/").casefold())
                require(not any(p.casefold() in (".codex", ".artifacts", ".env", ".git") for p in pieces), "archive-private-path")
                require(entry.file_size <= MAX_ARCHIVE and not entry.flag_bits & 1, "archive-entry-too-large-or-encrypted")
                mode = (entry.external_attr >> 16) & 0o170000
                require(mode in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK), "archive-special-file")
                if mode == stat.S_IFLNK:
                    require(entry.file_size <= 4096, "archive-link-too-long")
                    target = archive.read(entry).decode("utf-8")
                    require(target and not target.startswith("/") and "\\" not in target, "archive-unsafe-link")
                    links[tuple(p.casefold() for p in pieces)] = target.split("/")
            # Resolve link chains before '..'. Lexical checks alone can miss an escape.
            for link, target in links.items():
                pending = list(link[:-1]) + target
                components = []
                expansions = 0
                while pending:
                    part = pending.pop(0).casefold()
                    if part == "..":
                        require(len(components) > 1, "archive-link-escapes-app")
                        components.pop()
                    elif part not in ("", "."):
                        components.append(part)
                        require(components[0] == "lessmeet.app", "archive-link-escapes-app")
                        replacement = links.get(tuple(components))
                        if replacement is not None:
                            expansions += 1
                            require(expansions <= 1024, "archive-link-cycle-or-depth")
                            components.pop()
                            pending = replacement + pending
            require({"lessmeet.app/contents/info.plist", "lessmeet.app/contents/macos/lessmeet"} <= names,
                    "archive-not-completed-app-bundle")
            require(archive.testzip() is None, "archive-corrupt")
    except (zipfile.BadZipFile, RuntimeError, UnicodeError, OSError):
        raise Invalid("archive-invalid") from None


def checksums(files):
    return "".join("{}  {}\n".format(digest(files[name]), name) for name in sorted(files)).encode()


def manifest_plan(value):
    require(isinstance(value, dict) and set(value) == PLAN_KEYS | {"archive", "architecture", "signing", "notarized"},
            "invalid-release-schema")
    plan_value = validate_plan({k: value[k] for k in PLAN_KEYS})
    require(value["architecture"] == "arm64" and value["signing"] == "ad-hoc" and value["notarized"] is False,
            "invalid-diagnostic-distribution")
    archive = value["archive"]
    require(isinstance(archive, dict) and set(archive) == {"name", "sha256", "size"}
            and archive["name"] == value["archive_name"] and isinstance(archive["sha256"], str)
            and HASH.fullmatch(archive["sha256"]) and integer(archive["size"])
            and archive["size"] <= MAX_ARCHIVE, "invalid-archive-manifest")
    return plan_value


def seal(plan_path, archive_path, output_dir):
    value = validate_plan(decode(read(plan_path, MAX_METADATA)))
    archive_path = path_without_links(archive_path)
    require(archive_path.name == value["archive_name"], "archive-name-mismatch")
    archive = read(archive_path, MAX_ARCHIVE)
    validate_zip(archive)
    directory = path_without_links(output_dir)
    if not directory.exists():
        directory.mkdir(parents=True)
    require(directory.is_dir(), "invalid-seal-directory")
    entries = set(p.name for p in directory.iterdir())
    require(entries <= {value["archive_name"]}, "unexpected-seal-output")
    existing = directory / value["archive_name"]
    if entries:
        require(read(existing, MAX_ARCHIVE) == archive, "existing-archive-mismatch")
    else:
        write_new(existing, archive)
    release = {**value, "archive": {"name": value["archive_name"], "sha256": digest(archive), "size": len(archive)},
               "architecture": "arm64", "signing": "ad-hoc", "notarized": False}
    files = {value["archive_name"]: archive, "changelog.md": changelog(value), "release.json": encode(release)}
    for name in ("changelog.md", "release.json"):
        write_new(directory / name, files[name])
    write_new(directory / "SHA256SUMS", checksums(files))
    return release


def sealed(directory, expected_sha, repo):
    require(isinstance(expected_sha, str) and SHA.fullmatch(expected_sha), "invalid-expected-sha")
    repo = repository(repo)
    directory = path_without_links(directory)
    require(directory.is_dir(), "invalid-sealed-directory")
    manifest_bytes = read(directory / "release.json", MAX_METADATA)
    manifest = decode(manifest_bytes)
    plan_value = manifest_plan(manifest)
    require(manifest["source_sha"] == expected_sha and manifest["repository"] == repo, "sealed-binding-mismatch")
    names = {manifest["archive_name"], "release.json", "changelog.md", "SHA256SUMS"}
    require(set(p.name for p in directory.iterdir()) == names, "sealed-file-allowlist-mismatch")
    files = {name: read(directory / name, MAX_ARCHIVE if name == manifest["archive_name"] else MAX_METADATA)
             for name in names}
    require(files["release.json"] == encode(manifest) and files["changelog.md"] == changelog(plan_value),
            "sealed-metadata-not-canonical")
    archive = files[manifest["archive_name"]]
    require(digest(archive) == manifest["archive"]["sha256"] and len(archive) == manifest["archive"]["size"],
            "sealed-archive-digest-mismatch")
    require(files["SHA256SUMS"] == checksums({k: v for k, v in files.items() if k != "SHA256SUMS"}),
            "sealed-checksum-mismatch")
    validate_zip(archive)
    return manifest, files


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitHub:
    def __init__(self, repo, token, opener=None):
        self.repo = repository(repo)
        require(isinstance(token, str) and token and not any(ord(c) < 33 or ord(c) > 126 for c in token), "missing-or-invalid-gh-token")
        self.token = token
        self.opener = opener or urllib.request.build_opener(NoRedirect())

    def request(self, method, path, payload=None, binary=False, upload=False):
        prefix = "/repos/" + self.repo + "/"
        require(path.startswith(prefix) and "#" not in path and not any(ord(c) < 33 for c in path), "invalid-api-path")
        if upload:
            require(method == "POST" and re.fullmatch(re.escape(prefix) + r"releases/[1-9][0-9]*/assets\?name=[A-Za-z0-9_.%-]+", path), "invalid-upload-endpoint")
        else:
            require(method in ("GET", "POST", "PATCH") and not upload, "invalid-api-method")
        host = "uploads.github.com" if upload else "api.github.com"
        data = payload if isinstance(payload, bytes) else (encode(payload) if payload is not None else None)
        headers = {"Accept": "application/octet-stream" if binary else "application/vnd.github+json",
                   "Authorization": "Bearer " + self.token, "X-GitHub-Api-Version": API_VERSION,
                   "User-Agent": "LessMeet-diagnostic-release"}
        if data is not None:
            headers["Content-Type"] = "application/octet-stream" if upload else "application/json"
            headers["Content-Length"] = str(len(data))
        request = urllib.request.Request("https://" + host + path, data=data, headers=headers, method=method)
        try:
            try:
                response = self.opener.open(request, timeout=60)
            except urllib.error.HTTPError as error:
                if error.code != 302 or not binary or method != "GET" or upload:
                    raise APIError(error.code) from None
                location = error.headers.get("Location", "")
                try:
                    target = urllib.parse.urlsplit(location)
                    safe = (target.scheme == "https" and target.hostname in
                            ("release-assets.githubusercontent.com", "objects.githubusercontent.com")
                            and target.port in (None, 443) and target.username is None
                            and target.password is None and not target.fragment
                            and target.path.startswith("/") and not any(ord(c) < 33 for c in location))
                except ValueError:
                    safe = False
                require(safe, "github-asset-redirect-refused")
                # Signed query strings are sensitive. Never log Location or exceptions.
                request = urllib.request.Request(location, method="GET", headers={
                    "Accept": "application/octet-stream", "User-Agent": "LessMeet-diagnostic-release"})
                try:
                    response = self.opener.open(request, timeout=60)
                except urllib.error.HTTPError as second:
                    raise APIError(second.code) from None
            with response:
                require(response.geturl() == request.full_url, "github-redirect-refused")
                require(200 <= response.status < 300, "github-unexpected-status")
                body = response.read(MAX_METADATA + 1)
                require(len(body) <= MAX_METADATA, "github-metadata-too-large")
                return body if binary else decode(body)
        except (urllib.error.URLError, OSError, TimeoutError):
            raise Invalid("github-transport-outcome-unknown: rerun failed publish with original artifact") from None

    def json(self, method, endpoint, payload=None):
        return self.request(method, "/repos/" + self.repo + "/" + endpoint, payload)

    def download(self, asset_id):
        require(integer(asset_id), "invalid-asset-id")
        return self.request("GET", "/repos/{}/releases/assets/{}".format(self.repo, asset_id), binary=True)

    def upload(self, release_id, name, data):
        require(integer(release_id), "invalid-release-id")
        return self.request("POST", "/repos/{}/releases/{}/assets?name={}".format(
            self.repo, release_id, urllib.parse.quote(name, safe="")), data, upload=True)


def optional(call):
    try:
        return call()
    except APIError as error:
        if error.status == 404:
            return None
        raise


def pages(api, endpoint):
    items = []
    for page in range(1, 101):
        part = api.json("GET", endpoint + "?per_page=100&page=" + str(page))
        require(isinstance(part, list) and len(part) <= 100, "invalid-github-list")
        items.extend(part)
        if len(part) < 100:
            return items
    raise Invalid("github-pagination-bound-exceeded")


def tag_matches(api, value, create=False):
    endpoint = "git/ref/tags/" + value["tag"]
    ref = optional(lambda: api.json("GET", endpoint))
    if ref is None and create:
        try:
            api.json("POST", "git/refs", {"ref": "refs/tags/" + value["tag"], "sha": value["source_sha"]})
        except APIError as error:
            if error.status not in (409, 422):
                raise
        ref = optional(lambda: api.json("GET", endpoint))
    require(isinstance(ref, dict) and ref.get("ref") == "refs/tags/" + value["tag"]
            and isinstance(ref.get("object"), dict) and ref["object"].get("type") == "commit"
            and ref["object"].get("sha") == value["source_sha"], "tag-missing-or-not-exact-lightweight-sha")


def find_release(api, value):
    matches = [r for r in pages(api, "releases") if isinstance(r, dict) and r.get("tag_name") == value["tag"]]
    require(len(matches) <= 1, "duplicate-release-binding")
    return matches[0] if matches else None


def release_matches(release, value):
    require(isinstance(release, dict) and integer(release.get("id")) and type(release.get("draft")) is bool
            and release.get("tag_name") == value["tag"] and release.get("target_commitish") == value["source_sha"]
            and release.get("name") == value["tag"] and release.get("prerelease") is True
            and release.get("body") == changelog(value).decode(), "release-binding-mismatch")


def assets(api, release_id, allowed):
    result = {}
    for asset in pages(api, "releases/{}/assets".format(release_id)):
        require(isinstance(asset, dict) and asset.get("name") in allowed and asset["name"] not in result
                and integer(asset.get("id")) and asset.get("state") == "uploaded"
                and integer(asset.get("size")) and isinstance(asset.get("digest"), str)
                and re.fullmatch(r"sha256:[0-9a-f]{64}", asset["digest"]), RECOVERY)
        result[asset["name"]] = asset
    return result


def asset_matches(asset, data):
    require(asset["size"] == len(data) and asset["digest"] == "sha256:" + digest(data), RECOVERY)


def remote_complete(api, release, value, allowed, published=True):
    release_matches(release, value)
    require(release["draft"] is (not published), "release-state-mismatch")
    remote = assets(api, release["id"], allowed)
    require(set(remote) == allowed, "published-release-incomplete")
    manifest_data = api.download(remote["release.json"]["id"])
    remote_manifest = decode(manifest_data)
    remote_plan = manifest_plan(remote_manifest)
    require(remote_plan == {k: value[k] for k in PLAN_KEYS}, "remote-manifest-binding-mismatch")
    require(manifest_data == encode(remote_manifest), "remote-manifest-not-canonical")
    asset_matches(remote["release.json"], manifest_data)
    notes = api.download(remote["changelog.md"]["id"])
    require(notes == changelog(remote_plan), "remote-changelog-mismatch")
    asset_matches(remote["changelog.md"], notes)
    archive = remote[remote_manifest["archive_name"]]
    require(archive["size"] == remote_manifest["archive"]["size"]
            and archive["digest"] == "sha256:" + remote_manifest["archive"]["sha256"], "remote-archive-digest-mismatch")
    sums = api.download(remote["SHA256SUMS"]["id"])
    expected = {remote_manifest["archive_name"]: remote_manifest["archive"]["sha256"],
                "release.json": digest(manifest_data), "changelog.md": digest(notes)}
    require(sums == "".join("{}  {}\n".format(expected[n], n) for n in sorted(expected)).encode(), "remote-checksums-mismatch")
    asset_matches(remote["SHA256SUMS"], sums)
    return {"status": "already-published", "tag": value["tag"], "release_id": release["id"]}


def publish(directory, expected_sha, repo, execute=False, api=None):
    value, files = sealed(directory, expected_sha, repo)
    if not execute:
        return {"status": "dry-run", "source_sha": value["source_sha"], "tag": value["tag"], "assets": sorted(files)}
    api = api or GitHub(value["repository"], os.environ.get("GH_TOKEN", ""))
    allowed = set(files)
    release = find_release(api, value)
    if release is not None:
        release_matches(release, value)
        tag_matches(api, value)
        if not release["draft"]:
            return remote_complete(api, release, value, allowed)
        # Validate every existing byte binding before creating anything else.
        for name, asset in assets(api, release["id"], allowed).items():
            asset_matches(asset, files[name])
    else:
        tag_matches(api, value, create=True)
        try:
            api.json("POST", "releases", {"tag_name": value["tag"], "target_commitish": value["source_sha"],
                                          "name": value["tag"], "body": changelog(value).decode(),
                                          "draft": True, "prerelease": True, "make_latest": "false"})
        except APIError as error:
            if error.status not in (409, 422):
                raise
        release = find_release(api, value)
        release_matches(release, value)
        if not release["draft"]:
            return remote_complete(api, release, value, allowed)
    for name in sorted(files):
        current = api.json("GET", "releases/{}".format(release["id"]))
        release_matches(current, value)
        if not current["draft"]:
            return remote_complete(api, current, value, allowed)
        existing = assets(api, release["id"], allowed)
        for present, asset in existing.items():
            asset_matches(asset, files[present])
        if name not in existing:
            try:
                api.upload(release["id"], name, files[name])
            except APIError as error:
                if error.status not in (409, 422):
                    raise
            existing = assets(api, release["id"], allowed)
            require(name in existing, "upload-outcome-unconfirmed: rerun failed publish with original artifact")
            asset_matches(existing[name], files[name])
    # A final reread protects a concurrent published release from being edited.
    current = api.json("GET", "releases/{}".format(release["id"]))
    release_matches(current, value)
    if not current["draft"]:
        return remote_complete(api, current, value, allowed)
    complete = assets(api, release["id"], allowed)
    require(set(complete) == allowed, "draft-not-complete")
    for name, asset in complete.items():
        asset_matches(asset, files[name])
    tag_matches(api, value)
    # Check the remote manifest, notes and checksum bytes before publishing.
    remote_complete(api, current, value, allowed, published=False)
    api.json("PATCH", "releases/{}".format(release["id"]),
             {"draft": False, "prerelease": True, "make_latest": "false"})
    current = api.json("GET", "releases/{}".format(release["id"]))
    result = remote_complete(api, current, value, allowed)
    result["status"] = "published"
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("plan")
    p.add_argument("--event", required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--github-output")
    p.add_argument("--fetch-pr-head", action="store_true", help="Allow read-only GitHub fetch if captured PR objects are absent.")
    s = commands.add_parser("seal")
    s.add_argument("--plan", required=True)
    s.add_argument("--archive", required=True)
    s.add_argument("--output-dir", required=True)
    p = commands.add_parser("publish")
    p.add_argument("--directory", required=True)
    p.add_argument("--expected-sha", required=True)
    p.add_argument("--repo", required=True)
    p.add_argument("--execute", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.command == "plan":
            result = plan(args.event, args.repo, args.output, args.github_output, args.fetch_pr_head)
        elif args.command == "seal":
            result = seal(args.plan, args.archive, args.output_dir)
        else:
            result = publish(args.directory, args.expected_sha, args.repo, args.execute)
        print(json.dumps(result, sort_keys=True))
        return 0
    except Invalid as error:
        print("Release helper refused: " + str(error), file=sys.stderr)
    except Exception:
        # Do not expose urllib exceptions, event text, paths, response bodies or tokens.
        print("Release helper refused: local-or-remote-validation-failed", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
