#!/usr/bin/env python3
"""Offline validation of explicitly supplied macOS signing inputs. No key export."""
import argparse
import datetime as dt
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

BUNDLE = "com.lessmeet.app"
TEAM = "63M98WD275"
MODES = ("sandbox-dev", "store", "testflight")


class Invalid(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Invalid(message)


def run(args, **kwargs):
    try:
        return subprocess.run(args, check=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, **kwargs).stdout
    except (OSError, subprocess.CalledProcessError):
        raise Invalid("A signing metadata command failed; check supplied inputs and tools.") from None


def select_identity(output, requested):
    identities = re.findall(r'\b([A-Fa-f0-9]{40})\s+"([^"\n]+)"', output)
    matches = {(fingerprint.upper(), name) for fingerprint, name in identities
               if requested.upper() == fingerprint.upper() or requested == name}
    require(len(matches) == 1, "Signing identity must resolve to exactly one valid local identity.")
    fingerprint, name = matches.pop()
    require(not name.startswith("Developer ID"), "Developer ID is not a sandbox/store identity.")
    return fingerprint


def validate(profile, mode, fingerprint, certificate, device=None, now=None):
    """Pure policy validation; certificate metadata is obtained from the member DER."""
    require(mode in MODES, "Unknown signed packaging mode.")
    now = now or dt.datetime.now(dt.timezone.utc)
    require(isinstance(profile, dict), "Profile must be a dictionary.")
    platforms = profile.get("Platform", [])
    require(isinstance(platforms, list) and bool(set(platforms) & {"OSX", "macOS"})
            and set(platforms) <= {"OSX", "macOS"}, "Profile must target macOS only.")
    expiry = profile.get("ExpirationDate")
    require(isinstance(expiry, dt.datetime) and expiry.replace(tzinfo=dt.timezone.utc) > now,
            "Provisioning profile is expired or has no valid expiry.")
    creation = profile.get("CreationDate")
    require(isinstance(creation, dt.datetime) and creation.replace(tzinfo=dt.timezone.utc) <= now,
            "Provisioning profile is not yet valid or lacks a creation date.")
    require(profile.get("TeamIdentifier") == [TEAM], "Profile team must match the approved team.")
    ent = profile.get("Entitlements")
    require(isinstance(ent, dict), "Profile has no entitlement dictionary.")
    require(ent.get("com.apple.developer.team-identifier") == TEAM, "Profile entitlement team mismatch.")
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    require(isinstance(prefixes, list) and prefixes and all(isinstance(p, str) and re.fullmatch(r"[A-Z0-9]+", p) for p in prefixes),
            "Profile has invalid application identifier prefixes.")
    identifiers = {key: ent[key] for key in ("com.apple.application-identifier", "application-identifier") if key in ent}
    require(bool(identifiers) and len(set(identifiers.values())) == 1,
            "Profile requires an unambiguous application identifier.")
    require(all(value in [prefix + "." + BUNDLE for prefix in prefixes] for value in identifiers.values()),
            "Profile must authorize the exact bundle with its own application prefix; wildcards are rejected.")
    # TN3125: macOS sandbox/debug entitlements are unrestricted and may be absent
    # from the profile. The app's minimal signing template enables App Sandbox.
    require("com.apple.security.app-sandbox" not in ent or ent["com.apple.security.app-sandbox"] is True,
            "Profile explicitly contradicts App Sandbox.")
    members = profile.get("DeveloperCertificates", [])
    require(isinstance(members, list) and all(isinstance(c, bytes) for c in members), "Invalid profile certificates.")
    require(fingerprint.upper() in {hashlib.sha1(c).hexdigest().upper() for c in members},
            "Selected signing certificate is not a profile member.")
    require(certificate.get("team") == TEAM, "Signing certificate team mismatch.")
    require(certificate.get("valid") is True, "Signing certificate is not currently valid.")
    name = certificate.get("name", "")
    debug = [ent[key] for key in ("get-task-allow", "com.apple.security.get-task-allow") if key in ent]
    require(all(type(value) is bool for value in debug), "Invalid get-task-allow value.")
    if mode == "sandbox-dev":
        require(name.startswith("Apple Development:"), "sandbox-dev requires Apple Development.")
        require(all(debug), "Profile explicitly contradicts development signing.")
        devices = profile.get("ProvisionedDevices")
        require(isinstance(devices, list) and device and device.upper() in [str(d).upper() for d in devices],
                "Development profile must cover this Mac's provisioning UDID.")
        require(not profile.get("ProvisionsAllDevices"), "All-device profiles are not supported.")
    else:
        require(name.startswith(("Apple Distribution:", "Mac App Distribution:", "3rd Party Mac Developer Application:")),
                "store requires Apple Distribution or Mac App Distribution.")
        require(not any(debug), "Store profile must not permit get-task-allow.")
        require("ProvisionedDevices" not in profile and not profile.get("ProvisionsAllDevices"),
                "Store requires an App Store profile, not development/ad hoc/Developer ID.")
    # Deliberately do not copy profile keychain groups or other broad capabilities.
    return {**identifiers, "com.apple.developer.team-identifier": TEAM}


def certificate_metadata(der):
    with tempfile.TemporaryDirectory(prefix="lessmeet-certificate-") as folder:
        path = Path(folder) / "certificate.der"
        path.write_bytes(der)
        output = run(["/usr/bin/openssl", "x509", "-inform", "DER", "-in", str(path),
                      "-noout", "-subject", "-dates", "-nameopt", "sep_multiline,sname"]).decode()
    def field(name):
        match = re.search(r"^\s*" + name + r"\s*=\s*(.+)$", output, re.M)
        return match.group(1).strip() if match else ""
    try:
        start = dt.datetime.strptime(field("notBefore"), "%b %d %H:%M:%S %Y %Z").replace(tzinfo=dt.timezone.utc)
        end = dt.datetime.strptime(field("notAfter"), "%b %d %H:%M:%S %Y %Z").replace(tzinfo=dt.timezone.utc)
    except ValueError:
        raise Invalid("Certificate validity metadata could not be parsed.") from None
    return {"name": field("CN"), "team": field("OU"), "valid": start <= dt.datetime.now(dt.timezone.utc) < end}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=MODES)
    parser.add_argument("--output", help="New private staging directory for validated signing inputs")
    args = parser.parse_args()
    identity = os.environ.get("LESSMEET_SIGNING_IDENTITY", "").strip()
    profile_path = os.environ.get("LESSMEET_PROVISIONING_PROFILE", "").strip()
    require(identity and identity != "-", "Explicit signing identity is required; ad hoc signing is prohibited.")
    require(profile_path and Path(profile_path).is_file(), "Explicit provisioning profile file is required.")
    # Decode a private snapshot so embedding uses precisely the bytes validated here.
    original = Path(profile_path).read_bytes()
    with tempfile.TemporaryDirectory(prefix="lessmeet-profile-") as folder:
        snapshot = Path(folder) / "profile.provisionprofile"
        snapshot.write_bytes(original)
        decoded = run(["/usr/bin/security", "cms", "-D", "-i", str(snapshot)])
    profile = plistlib.loads(decoded)
    fingerprint = select_identity(run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"]).decode(), identity)
    der = next((c for c in profile.get("DeveloperCertificates", [])
                if isinstance(c, bytes) and hashlib.sha1(c).hexdigest().upper() == fingerprint), None)
    require(der is not None, "Selected signing certificate is not a profile member.")
    device = None
    if args.mode == "sandbox-dev":
        # Provisioning UDID is reported by system_profiler (not necessarily IOPlatformUUID on Apple Silicon).
        hardware = __import__("json").loads(run(["/usr/sbin/system_profiler", "SPHardwareDataType", "-json"]))
        data = hardware["SPHardwareDataType"][0]
        device = data.get("provisioning_UDID") or data.get("platform_UUID")
    generated = validate(profile, args.mode, fingerprint, certificate_metadata(der), device)
    template = Path(__file__).resolve().parent.parent / "Resources/LessMeet.sandbox.entitlements"
    entitlements = plistlib.loads(template.read_bytes())
    require(entitlements == {"com.apple.security.app-sandbox": True,
                             "com.apple.security.network.client": True,
                             "com.apple.security.device.audio-input": True}, "Sandbox template contains unexpected capabilities.")
    entitlements.update(generated)
    if args.output:
        output = Path(args.output)
        output.mkdir(mode=0o700, parents=False, exist_ok=False)
        (output / "embedded.provisionprofile").write_bytes(original)
        (output / "entitlements.plist").write_bytes(plistlib.dumps(entitlements))
        (output / "identity.txt").write_text(fingerprint + "\n")
    print("Signing preflight passed (profile, certificate, team, bundle, mode and device policy).")


if __name__ == "__main__":
    try:
        main()
    except Invalid as error:
        print("Signing preflight failed: " + str(error), file=sys.stderr)
        sys.exit(1)
    except Exception:
        # Profile/configuration bytes, paths and subprocess output must not leak.
        print("Signing preflight failed: malformed or unreadable signing metadata.", file=sys.stderr)
        sys.exit(1)
