#!/usr/bin/env python3
"""Build a merged commit for GitHub. Never sign for Apple distribution or upload."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import signal
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
RESOURCE_BUNDLES = (
    "Clerk_ClerkKit.bundle", "LessMeet_LessMeet.bundle",
    "swift-transformers_Hub.bundle", "swift-crypto_Crypto.bundle",
)
PUBLIC_PROPERTIES = (
    "ClerkPublishableKey", "ConvexSiteURL", "RevenueCatPublicAppleKey",
    "LessMeetPrivacyURL", "LessMeetTermsURL", "CFBundleURLTypes",
)


class BuildError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise BuildError(message)


def build_environment():
    # Compile dependencies must not inherit workflow publishing or Apple tokens.
    names = (
        "PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL",
        "DEVELOPER_DIR", "SDKROOT", "TERM", "TZ", "CI", "GITHUB_ACTIONS",
        "MACOSX_DEPLOYMENT_TARGET", "GITHUB_WORKSPACE", "RUNNER_TEMP", "RUNNER_TRACKING_ID",
    )
    result = {name: os.environ[name] for name in names if name in os.environ}
    result["LESSMEET_SIGNING_IDENTITY"] = "-"
    return result


def run(args, stage, *, timeout=120, visible=False):
    try:
        process = subprocess.Popen(
            [str(arg) for arg in args], cwd=ROOT, env=build_environment(),
            text=True, stdout=None if visible else subprocess.PIPE,
            stderr=None if visible else subprocess.PIPE, start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Kill only this command's owned group, including compiler children.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=10)
            raise
    except (OSError, subprocess.TimeoutExpired):
        raise BuildError(f"{stage} failed or timed out; no release was published.") from None
    finally:
        if "process" in locals():
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    stream.close()
    require(process.returncode == 0, f"{stage} failed; no release was published.")
    return (stdout or "") + (stderr or "")


def digest(path):
    with path.open("rb") as stream:
        checksum = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def load_plan(path):
    require(path.is_file() and not path.is_symlink(), "Plan must be a regular file.")
    plan = json.loads(path.read_text())
    sha = plan.get("source_sha", "")
    sequence = plan.get("sequence")
    require(isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{40}", sha), "Invalid source SHA.")
    require(type(sequence) is int and sequence > 0, "Invalid release sequence.")
    signed = plan.get("schema") == 3
    tag = f"{'main-signed' if signed else 'main-build'}-{sequence}-{sha}"
    require(plan.get("tag") == tag, "Invalid release tag.")
    suffix = "developer-id" if signed else "adhoc"
    require(plan.get("archive_name") == f"LessMeet-{tag}-macos-arm64-{suffix}.zip", "Invalid archive name.")
    require(run(["git", "rev-parse", "HEAD"], "Source identity").strip() == sha, "Checkout does not match merge SHA.")
    require(int(run(["git", "rev-list", "--first-parent", "--count", "HEAD"], "Source order")) == sequence,
            "Release sequence does not match source history.")
    return plan


def verify_app(app):
    require(app.is_dir() and not app.is_symlink(), "Built app is missing or is a symlink.")
    info_path = app / "Contents/Info.plist"
    binary = app / "Contents/MacOS/LessMeet"
    require(info_path.is_file() and not info_path.is_symlink(), "Built app metadata is missing.")
    require(binary.is_file() and not binary.is_symlink(), "Built executable is missing.")
    info = plistlib.loads(info_path.read_bytes())
    require(info.get("LessMeetPackagingMode") == "local", "Only local packaging is permitted.")
    require(info.get("CFBundleIdentifier") == "com.lessmeet.app.local", "Unexpected local bundle identity.")
    require(all(key not in info for key in PUBLIC_PROPERTIES), "Service configuration is not allowed in this package.")
    require(not (app / "Contents/embedded.provisionprofile").exists(), "Distribution profile is not allowed.")
    architecture = run(["/usr/bin/lipo", "-archs", binary], "Architecture verification").strip()
    require(architecture == "arm64", "Expected an arm64-only executable.")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], "Signature verification")
    signature = run(["/usr/bin/codesign", "--display", "--verbose=4", app], "Signature identity")
    require("Signature=adhoc" in signature.splitlines(), "Expected an ad-hoc signature.")
    verify_resources(app)
    return {"architecture": architecture, "signing": "ad-hoc", "notarized": False,
            "bundle_identifier": info["CFBundleIdentifier"],
            "app_version": info["CFBundleShortVersionString"], "app_build": info["CFBundleVersion"],
            "executable_sha256": digest(binary)}


def verify_resources(app):
    """Shared resource gate; signed-local does not weaken the diagnostic gate."""
    for name in RESOURCE_BUNDLES:
        require((app / "Contents/Resources" / name).is_dir(), "A required resource bundle is missing.")
    shader = app / "Contents/Resources/mlx.metallib"
    shader_link = app / "Contents/MacOS/mlx.metallib"
    require(shader.is_file() and shader.stat().st_size > 0, "Metal library is missing.")
    require(shader_link.is_symlink() and os.readlink(shader_link) == "../Resources/mlx.metallib",
            "Metal library lookup link is invalid.")
    for notice in (ROOT / "Resources/ModelLicenses").iterdir():
        if notice.is_file():
            bundled = app / "Contents/Resources/ModelLicenses" / notice.name
            require(bundled.is_file() and digest(notice) == digest(bundled), "Model notice is missing or changed.")


def build(plan_path, output, execute=False, prepare=False):
    plan = load_plan(plan_path)
    require(prepare == (plan.get("schema") == 3), "Signed plans require prepare-only; no ad-hoc fallback.")
    require(not output.exists(), "Use a new output directory; existing release inputs are immutable.")
    if not execute:
        return {"mode": "dry-run", "source_sha": plan["source_sha"], "archive_name": plan["archive_name"],
                "steps": ["check toolchain", "build local", "verify arm64/ad-hoc/resources"] + ([] if prepare else ["archive", "seal"]),
                "published": False}
    require(platform.system() == "Darwin" and platform.machine() == "arm64", "An Apple Silicon macOS runner is required.")
    xcode = run(["xcodebuild", "-version"], "Xcode check")
    require("Xcode 26.6" in xcode.splitlines() and "Build version 17F113" in xcode.splitlines(),
            "Expected Xcode 26.6 (17F113); no fallback toolchain is selected.")
    run(["xcrun", "-sdk", "macosx", "metal", "--version"], "Metal compiler check")
    run(["node", "--input-type=module", "-e", 'import { parseEnv } from "node:util"; parseEnv("");'], "Node capability check")
    # This existing script verifies pinned dependency revisions and resource copies.
    run(["bash", "scripts/build-app.sh", "local"], "Local build", timeout=1200, visible=True)
    run(["git", "diff", "--exit-code", "--", "Package.swift", "Package.resolved", "Sources", "Resources"],
        "Unchanged source and pins")
    app = ROOT / "dist/local/LessMeet.app"
    summary = verify_app(app)
    if prepare:
        return {"mode": "prepared-unsigned", "source_sha": plan["source_sha"], "verification": summary,
                "published": False}
    output.mkdir(parents=True)
    archive = output / plan["archive_name"]
    # Exclude filesystem metadata and __MACOSX sidecars, not bundle resources.
    run(["/usr/bin/ditto", "-c", "-k", "--norsrc", "--noextattr", "--noacl",
         "--keepParent", app, archive], "Archive", timeout=300)
    run([sys.executable, "scripts/github-release.py", "seal", "--plan", plan_path,
         "--archive", archive, "--output-dir", output], "Seal release inputs")
    return {"mode": "built", "source_sha": plan["source_sha"], "verification": summary,
            "published": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--execute", action="store_true", help="Compile and package. Default only validates the plan.")
    parser.add_argument("--prepare", action="store_true", help="Prepare unsigned inputs for a schema-3 signing stage; do not archive or seal")
    args = parser.parse_args()
    try:
        result = build(args.plan.absolute(), args.output_dir.absolute(), args.execute, args.prepare)
        print(json.dumps(result, indent=2))
        return 0
    except (BuildError, OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException) as error:
        # Raw process output, environment values and file contents never enter errors.
        message = str(error) if isinstance(error, BuildError) else "Invalid release build input."
        print(f"Release build: {message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
