#!/usr/bin/env python3
"""Opt-in hosted CI signing/notarization. No local invocation or implicit upload."""
import argparse
import base64
from contextlib import contextmanager
from functools import wraps
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import signal
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
import importlib.util
spec = importlib.util.spec_from_file_location("local_signer", Path(__file__).with_name("sign-local-app.py"))
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)
release = signer.module("release", "github-release.py")
require = signer.require
Invalid = signer.Invalid
SECRET_NAMES = (
    "LESSMEET_DEVELOPER_ID_P12_BASE64", "LESSMEET_DEVELOPER_ID_P12_PASSWORD",
    "LESSMEET_DEVELOPER_ID_PROFILE_BASE64", "LESSMEET_DEVELOPER_ID_CERT_SHA1",
    "LESSMEET_NOTARY_KEY_BASE64", "LESSMEET_NOTARY_KEY_ID", "LESSMEET_NOTARY_ISSUER_ID",
)

# Only source-defined labels enter logs. Never format exceptions or arguments.
STAGES = frozenset((
    "runner-preflight", "signing-pipeline", "cleanup", "plan-validation",
    "unsigned-app-validation", "profile-validation", "keychain-create",
    "keychain-unlock", "certificate-import", "keychain-access", "identity-check",
    "app-signing", "notarization", "submission-archive", "notary-submit",
    "staple", "staple-validation", "gatekeeper-assessment", "signed-app-validation",
    "archive-validation", "release-seal", "secret-validation", "private-inputs",
    "identity-validation", "notary-response", "output-validation", "private-workspace",
    "signed-workspace", "archive-create", "archive-structure", "archive-extract",
    "archive-staple", "archive-assessment", "archive-consistency", "receipt-write",
)) | signer.SIGN_STAGES


@contextmanager
def stage(name):
    require(name in STAGES, "Unknown diagnostic stage.")
    def emit(outcome):
        try:
            print(f"CI signing stage {name}: {outcome}", flush=True)
        except Exception:
            # A broken log stream must not skip cleanup or replace an outcome.
            pass
    emit("started")
    try:
        yield
    except BaseException:
        emit("failed")
        raise
    else:
        emit("passed")


def traced(name):
    def decorate(function):
        @wraps(function)
        def wrapped(*args, **kwargs):
            with stage(name):
                return function(*args, **kwargs)
        return wrapped
    return decorate


def step(name, function, *args, **kwargs):
    with stage(name):
        return function(*args, **kwargs)


@traced("runner-preflight")
def private_root():
    require(os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted",
            "This command requires an explicitly enabled GitHub-hosted job.")
    run_id, attempt = os.environ.get("GITHUB_RUN_ID", ""), os.environ.get("GITHUB_RUN_ATTEMPT", "")
    require(re.fullmatch(r"[1-9][0-9]*", run_id) and re.fullmatch(r"[1-9][0-9]*", attempt), "Invalid run identity.")
    root = Path(os.environ.get("RUNNER_TEMP", ""))
    require(root.is_absolute() and root.is_dir() and root != Path("/"), "Invalid runner temporary directory.")
    signer.no_links(root)
    return root / ("lessmeet-signing-" + run_id + "-" + attempt)


@traced("cleanup")
def cleanup(root):
    # Only this run's private files. Never touch login/default Keychains or use
    # recursive removal with an environment-selected root.
    if not root.exists():
        return
    signer.no_links(root)
    signer.regular(root / "owner")
    require((root / "owner").read_text() == "LessMeet ephemeral signing\n", "Unowned cleanup directory.")
    failed = False
    keychain = root / "signing.keychain-db"
    if keychain.exists():
        try:
            signer.regular(keychain)
            signer.run(["/usr/bin/security", "delete-keychain", keychain])
        except Exception:
            failed = True
    # A failed keychain operation must not retain the import or notary payloads.
    # Keep the owner marker until all operations succeed so cleanup can retry.
    for name in ("certificate.p12", "profile.provisionprofile", "notary.p8"):
        path = root / name
        try:
            if path.exists():
                signer.regular(path)
                path.unlink()
        except Exception:
            failed = True
    require(not failed, "Some owned signing inputs could not be removed; cleanup must be retried.")
    require(set(p.name for p in root.iterdir()) == {"owner"}, "Unexpected signing files remain; do not publish.")
    (root / "owner").unlink()
    root.rmdir()


def secret_file(root, name, encoded):
    try:
        data = base64.b64decode(encoded, validate=True)
    except (ValueError, TypeError):
        raise Invalid("Malformed signing input encoding.") from None
    require(0 < len(data) <= 1024 * 1024, "Invalid signing input size.")
    path = root / name
    with path.open("xb") as stream:
        os.chmod(path, 0o600)
        stream.write(data)
    return path


@traced("notarization")
def notarize(app, submission, credentials):
    step("submission-archive", signer.run, ["/usr/bin/ditto", "-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent", app, submission])
    # Bounded wait; timeout/invalid/unknown responses must not seal or publish.
    response = step("notary-submit", signer.run, ["xcrun", "notarytool", "submit", submission, "--key", credentials[0],
                                "--key-id", credentials[1], "--issuer", credentials[2], "--wait",
                                "--timeout", "15m", "--output-format", "json"], timeout=960)
    with stage("notary-response"):
        try:
            result = json.loads(response)
            identifier = str(uuid.UUID(result["id"]))
        except (ValueError, KeyError, TypeError):
            raise Invalid("Invalid notarization response; do not publish.") from None
        require(result.get("status") == "Accepted", "Notarization was not accepted; do not publish.")
    step("staple", signer.run, ["xcrun", "stapler", "staple", app])
    step("staple-validation", signer.run, ["xcrun", "stapler", "validate", app])
    step("gatekeeper-assessment", signer.run, ["/usr/sbin/spctl", "--assess", "--type", "execute", app])
    return identifier


@traced("signing-pipeline")
def execute(plan_path, output, root):
    with stage("plan-validation"):
        plan = release.validate_plan(release.decode(release.read(plan_path, release.MAX_METADATA)))
        require(plan["schema"] == 3, "Only Developer ID release plans may use this stage.")
        signer.build.load_plan(plan_path)
    with stage("output-validation"):
        require(not output.exists(), "Existing release inputs are immutable.")
        signer.no_links(output.absolute())
    # Check the unsigned bundle before materializing any secret files.
    step("unsigned-app-validation", signer.build.verify_app, signer.ROOT / "dist/local/LessMeet.app")
    with stage("secret-validation"):
        values = {name: os.environ.pop(name, "") for name in SECRET_NAMES}
        require(all(values.values()), "Required Developer ID and notarization inputs are missing.")
        fingerprint = values["LESSMEET_DEVELOPER_ID_CERT_SHA1"]
        require(re.fullmatch(r"[A-Fa-f0-9]{40}", fingerprint), "Invalid certificate fingerprint.")
        require(re.fullmatch(r"[A-Z0-9]{10}", values["LESSMEET_NOTARY_KEY_ID"]), "Invalid notary key ID.")
        try:
            uuid.UUID(values["LESSMEET_NOTARY_ISSUER_ID"])
        except ValueError:
            raise Invalid("Invalid notary issuer ID.") from None
    with stage("private-workspace"):
        root.mkdir(mode=0o700, exist_ok=False)
        (root / "owner").write_text("LessMeet ephemeral signing\n")
    try:
        profile = step("private-inputs", secret_file, root, "profile.provisionprofile", values["LESSMEET_DEVELOPER_ID_PROFILE_BASE64"])
        # Reject development/Store/wrong/expired profiles before importing a key.
        original, entitlements = step("profile-validation", signer.inputs, profile, fingerprint, "developer-id")
        p12 = step("private-inputs", secret_file, root, "certificate.p12", values["LESSMEET_DEVELOPER_ID_P12_BASE64"])
        notary_key = step("private-inputs", secret_file, root, "notary.p8", values["LESSMEET_NOTARY_KEY_BASE64"])
        password = secrets.token_urlsafe(40)
        keychain = root / "signing.keychain-db"
        step("keychain-create", signer.run, ["/usr/bin/security", "create-keychain", "-p", password, keychain])
        step("keychain-unlock", signer.run, ["/usr/bin/security", "unlock-keychain", "-p", password, keychain])
        step("certificate-import", signer.run, ["/usr/bin/security", "import", p12, "-k", keychain, "-P", values["LESSMEET_DEVELOPER_ID_P12_PASSWORD"],
                    "-T", "/usr/bin/codesign"])
        step("keychain-access", signer.run, ["/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, keychain])
        # No search-list/default-keychain changes. Select only the new keychain.
        identity_bytes = step("identity-check", signer.run, ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning", keychain])
        with stage("identity-validation"):
            identities = identity_bytes.decode()
            found = re.findall(r'\b([A-Fa-f0-9]{40})\s+"([^"\n]+)"', identities)
            require(len(found) == 1 and found[0][0].upper() == fingerprint.upper() and found[0][1].startswith("Developer ID Application:"),
                    "Imported keychain must contain only the selected Developer ID identity.")
        with stage("signed-workspace"):
            work = signer.ROOT / "dist" / ("developer-id-" + root.name)
            work.mkdir(parents=True, exist_ok=False)
        app = work / "LessMeet.app"
        step("app-signing", signer.sign, signer.ROOT / "dist/local/LessMeet.app", app, profile, fingerprint, keychain, "developer-id", diagnostic=stage)
        identifier = notarize(app, work / "submission.zip", (notary_key, values["LESSMEET_NOTARY_KEY_ID"], values["LESSMEET_NOTARY_ISSUER_ID"]))
        summary = step("signed-app-validation", signer.verify, app, fingerprint, original, entitlements, "developer-id")
        with stage("archive-create"):
            output.mkdir(parents=True, exist_ok=False)
            archive = output / plan["archive_name"]
            signer.run(["/usr/bin/ditto", "-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent", app, archive])
        # Check the artifact bytes that will be distributed, including the
        # archived staple, rather than relying on the pre-archive app alone.
        with stage("archive-structure"):
            release.validate_zip(release.read(archive, release.MAX_ARCHIVE), signed=True)
        extracted = work / "archive-check"
        step("archive-extract", signer.run, ["/usr/bin/ditto", "-x", "-k", archive, extracted])
        archived_app = extracted / "LessMeet.app"
        step("archive-staple", signer.run, ["xcrun", "stapler", "validate", archived_app])
        step("archive-assessment", signer.run, ["/usr/sbin/spctl", "--assess", "--type", "execute", archived_app])
        archived_summary = step("archive-validation", signer.verify, archived_app, fingerprint, original, entitlements, "developer-id")
        with stage("archive-consistency"):
            require(archived_summary == summary, "Final archive differs from the verified signed app.")
        verification = {"certificate_sha1": fingerprint.upper(), "team_id": signer.policy.TEAM,
                        "profile_sha256": summary["profile_sha256"], "executable_sha256": summary["executable_sha256"],
                        "notarization_id": identifier, "status": "Accepted", "stapled": True}
        receipt = work / "verification.json"
        with stage("receipt-write"):
            receipt.write_bytes(release.encode({"source_sha": plan["source_sha"], "archive_sha256": signer.build.digest(archive),
                                                "verification": verification}))
        step("release-seal", release.seal, plan_path, archive, output, receipt)
    finally:
        cleanup(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--cleanup", action="store_true")
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    root = private_root()
    if args.cleanup:
        cleanup(root)
        return
    require(args.execute and args.plan is not None and args.output_dir is not None,
            "Explicit execute, plan and output are required; notarization has external effects.")
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(Invalid("Signing interrupted.")))
    execute(args.plan, args.output_dir, root)
    print("Developer ID signature, notarization, stapling and sealed archive verified; not published.")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never emit commands, secret paths, process output, passwords or payloads.
        print("CI signing failed; no publication authorized. Check stage markers above.", file=sys.stderr)
        sys.exit(1)
