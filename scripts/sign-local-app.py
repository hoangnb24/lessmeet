#!/usr/bin/env python3
"""Sign a separate local development app. Never launch, upload or publish it."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


policy = module("signing_policy", "packaging-signing.py")
build = module("diagnostic_build", "build-github-release.py")
Invalid = policy.Invalid
require = policy.require


def run(args, timeout=120):
    # No signing payloads, publishing tokens or operator configuration reach
    # child processes. Explicit paths/fingerprint are passed as arguments.
    try:
        result = subprocess.run([str(a) for a in args], cwd=ROOT,
                                env=build.build_environment(), capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        raise Invalid("Signing command failed or timed out.") from None
    require(result.returncode == 0, "Signing command failed; no candidate was promoted.")
    return result.stdout


def regular(path):
    require(path.is_file() and not path.is_symlink(), "Expected a regular input file.")


def no_links(path):
    for parent in (path, *path.parents):
        require(not parent.is_symlink(), "Linked input/output paths are not supported.")


def inputs(profile_path, fingerprint, mode="signed-local"):
    require(mode in ("signed-local", "developer-id"), "Unsupported profile signing mode.")
    require(isinstance(fingerprint, str) and re.fullmatch(r"[a-fA-F0-9]{40}", fingerprint),
            "An exact certificate SHA1 is required; no ad-hoc fallback.")
    fingerprint = fingerprint.upper()
    regular(profile_path)
    original = profile_path.read_bytes()
    with tempfile.TemporaryDirectory(prefix="lessmeet-profile-") as folder:
        snapshot = Path(folder) / "profile"
        snapshot.write_bytes(original)
        profile = plistlib.loads(run(["/usr/bin/security", "cms", "-D", "-i", snapshot]))
    der = next((c for c in profile.get("DeveloperCertificates", [])
                if isinstance(c, bytes) and hashlib.sha1(c).hexdigest().upper() == fingerprint), None)
    require(der is not None, "Selected certificate is not a member of this profile.")
    generated = policy.validate(profile, mode, fingerprint, policy.certificate_metadata(der))
    template = plistlib.loads((ROOT / "Resources/LessMeet.entitlements").read_bytes())
    require(template == {"com.apple.security.device.audio-input": True}, "Unexpected signing capabilities.")
    return original, {**template, **generated}


def verify(app, fingerprint, original, entitlements, mode="signed-local"):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == policy.BUNDLE and info.get("LessMeetPackagingMode") == mode,
            "Signed bundle identity or mode mismatch.")
    require(all(k not in info for k in build.PUBLIC_PROPERTIES), "Unexpected service configuration.")
    require((app / "Contents/embedded.provisionprofile").read_bytes() == original, "Embedded profile changed.")
    binary = app / "Contents/MacOS/LessMeet"
    require(run(["/usr/bin/lipo", "-archs", binary]).decode().strip() == "arm64", "Expected arm64.")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    if mode == "developer-id":
        # codesign writes display metadata to stderr. Capture it separately.
        details = build.run(["/usr/bin/codesign", "--display", "--verbose=4", app], "Signing metadata")
        require("Timestamp=" in details and "(runtime)" in details, "Secure timestamp and hardened runtime required.")
    actual = plistlib.loads(run(["/usr/bin/codesign", "--display", "--entitlements", ":-", app]))
    require(actual == entitlements, "Signed entitlement allowlist mismatch.")
    with tempfile.TemporaryDirectory(prefix="lessmeet-leaf-") as folder:
        prefix = Path(folder) / "certificate"
        run(["/usr/bin/codesign", "--display", "--extract-certificates=" + str(prefix), app])
        leaf = Path(str(prefix) + "0")
        regular(leaf)
        require(hashlib.sha1(leaf.read_bytes()).hexdigest().upper() == fingerprint.upper(),
                "Signature leaf does not match the selected certificate.")
    build.verify_resources(app)
    return {"signing": "developer-id" if mode == "developer-id" else "profile-backed-development", "bundle_identifier": policy.BUNDLE,
            "architecture": "arm64", "notarized": False, "runtime": "unverified",
            "executable_sha256": build.digest(binary), "profile_sha256": hashlib.sha256(original).hexdigest()}


def sign(source, output, profile_path, fingerprint, keychain=None, mode="signed-local"):
    source, output = source.absolute(), output.absolute()
    no_links(source)
    no_links(output)
    require(output.suffix == ".app" and not output.exists(), "Use a new .app output; never overwrite a candidate.")
    require(not output.is_relative_to(source), "Output must be outside the input app.")
    # Reject external resource links before copying or opening bundled inputs.
    for entry in source.rglob("*"):
        if entry.is_symlink():
            require(entry.resolve().is_relative_to(source.resolve()), "Resource link escapes the input bundle.")
    build.verify_app(source)
    original, entitlements = inputs(profile_path, fingerprint, mode)
    if keychain is not None:
        regular(keychain)
    output.parent.mkdir(parents=True, exist_ok=True)
    # Nothing is promoted until every check passes. Failed scratch is private.
    with tempfile.TemporaryDirectory(prefix="signing-", dir=output.parent) as folder:
        stage = Path(folder)
        app = stage / "LessMeet.app"
        shutil.copytree(source, app, symlinks=True)
        run(["node", ROOT / "scripts/configure-app.mjs", app / "Contents/Info.plist", "signed-local"])
        if mode == "developer-id":
            info_path = app / "Contents/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            info["LessMeetPackagingMode"] = "developer-id"
            info_path.write_bytes(plistlib.dumps(info))
        (app / "Contents/embedded.provisionprofile").write_bytes(original)
        entitlement_path = stage / "entitlements.plist"
        entitlement_path.write_bytes(plistlib.dumps(entitlements))
        args = ["/usr/bin/codesign", "--force", "--sign", fingerprint.upper(), "--options", "runtime",
                "--entitlements", entitlement_path]
        if keychain is not None:
            args += ["--keychain", keychain]
        if mode == "developer-id":
            args += ["--timestamp"]
        run([*args, app])
        summary = verify(app, fingerprint, original, entitlements, mode)
        require(not output.exists(), "Output appeared during signing; refusing promotion.")
        app.rename(output)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true", help="Compile local without signing inputs first")
    parser.add_argument("--app", type=Path, default=ROOT / "dist/local/LessMeet.app")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    profile = os.environ.get("LESSMEET_PROVISIONING_PROFILE", "")
    fingerprint = os.environ.get("LESSMEET_SIGNING_IDENTITY", "")
    require(profile and re.fullmatch(r"[a-fA-F0-9]{40}", fingerprint or ""), "Explicit signing inputs are required.")
    require(not args.output.exists(), "Use a new output; existing candidates are immutable.")
    if args.build:
        # Secrets remain in this parent, not in compiler/dependency environments.
        build.run(["bash", "scripts/build-app.sh", "local"], "Local build", timeout=1200, visible=True)
    print(json.dumps(sign(args.app, args.output, Path(profile), fingerprint), sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (Invalid, build.BuildError) as error:
        print("Local signing failed: " + str(error), file=sys.stderr)
        sys.exit(1)
    except Exception:
        print("Local signing failed: invalid or unreadable input.", file=sys.stderr)
        sys.exit(1)
