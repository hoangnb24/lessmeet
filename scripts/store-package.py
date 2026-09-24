#!/usr/bin/env python3
"""Local Store gates and isolated installer preparation; never uploads or installs.

See Tests/packaging/STORE_INPUTS.md before use. `inputs` touches no signing inputs.
`package` requires separate authorization to access signing inputs and sign a pkg.
"""
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

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("signing", Path(__file__).with_name("packaging-signing.py"))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
require = signing.require
Invalid = signing.Invalid
PUBLIC = {
    "CLERK_PUBLISHABLE_KEY": "ClerkPublishableKey",
    "CONVEX_SITE_URL": "ConvexSiteURL",
    "REVENUECAT_PUBLIC_APPLE_KEY": "RevenueCatPublicAppleKey",
    "LESSMEET_PRIVACY_URL": "LessMeetPrivacyURL",
    "LESSMEET_TERMS_URL": "LessMeetTermsURL",
}


def run(args):
    try:
        result = subprocess.run([str(a) for a in args], check=True, capture_output=True,
                                env={**os.environ, "LC_ALL": "C"})
        return result.stdout
    except (OSError, subprocess.CalledProcessError):
        raise Invalid("Apple packaging command failed; no installer accepted.") from None


def digest(data):
    return hashlib.sha256(data).hexdigest()


def inputs():
    version = os.environ.get("LESSMEET_VERSION", "")
    build = os.environ.get("LESSMEET_BUILD", "")
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version), "Explicit three-component LESSMEET_VERSION required.")
    require(re.fullmatch(r"[1-9][0-9]{0,3}(\.[0-9]{1,2}){0,2}", build),
            "Explicit release LESSMEET_BUILD required (positive major, up to 4.2.2 digits).")
    approval_path = os.environ.get("LESSMEET_STORE_APPROVAL", "")
    require(approval_path and Path(approval_path).is_file(), "Explicit public LESSMEET_STORE_APPROVAL record required.")
    approval = json.loads(Path(approval_path).read_text())
    require(approval.get("schema") == 1 and approval.get("bundle") == signing.BUNDLE
            and approval.get("team") == signing.TEAM, "Store approval schema, bundle or team mismatch.")
    require(approval.get("version") == version and approval.get("build") == build, "Approval version/build mismatch.")
    public = {key: os.environ.get(key, "").strip() for key in PUBLIC}
    require(all(public.values()) and approval.get("public_configuration") == public, "Approval must bind every public configuration value exactly.")
    # Reuse public syntactic validation. No .env fallback and no secret inputs.
    run(["node", Path(__file__).with_name("configure-app.mjs"), "--check", "store"])
    for key in ("production_backend_evidence", "production_auth_billing_evidence", "published_legal_evidence",
                "approved_icon_evidence", "approved_by"):
        require(isinstance(approval.get(key), str) and approval[key].strip(), "Missing explicit Store approval evidence: " + key)
    icon_path = os.environ.get("LESSMEET_ICON_ICNS", "")
    require(icon_path and Path(icon_path).is_file() and Path(icon_path).suffix == ".icns", "Approved LESSMEET_ICON_ICNS input required.")
    icon = Path(icon_path).read_bytes()
    require(icon[:4] == b"icns" and len(icon) >= 8 and int.from_bytes(icon[4:8], "big") == len(icon), "Invalid ICNS container.")
    require(approval.get("icon_sha256") == digest(icon), "Icon bytes differ from approval.")
    validate_icon(icon)
    return version, build, public, icon, approval


def validate_icon(icon):
    # Validate a byte snapshot, not a mutable input path. No artwork generation.
    with tempfile.TemporaryDirectory(prefix="lessmeet-icon-") as folder:
        path = Path(folder) / "Approved.icns"
        path.write_bytes(icon)
        iconset = Path(folder) / "Approved.iconset"
        run(["/usr/bin/iconutil", "-c", "iconset", "-o", iconset, path])
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                png = iconset / ("icon_%dx%d%s.png" % (size, size, "@2x" if scale == 2 else ""))
                require(png.is_file(), "Approved icon must include all standard and Retina representations.")
                metadata = run(["/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", png]).decode()
                for dimension in ("pixelWidth", "pixelHeight"):
                    require(re.search(r"\b" + dimension + r":\s*" + str(size * scale) + r"\s*$", metadata, re.M),
                            "Icon representation has incorrect pixel dimensions.")


def stamp(app, values):
    # Only called by build-app on its fresh, unsigned staging bundle.
    require(not (app / "Contents/_CodeSignature").exists(), "Refusing to change a signed bundle.")
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    version, build, public, icon, _ = values
    require(info.get("LessMeetPackagingMode") == "store", "Only store staging bundles may be stamped.")
    require(all(info.get(prop) == public[key] for key, prop in PUBLIC.items()), "Staging public configuration mismatch.")
    info.update(CFBundleShortVersionString=version, CFBundleVersion=build, CFBundleIconFile="LessMeet.icns")
    (app / "Contents/Resources/LessMeet.icns").write_bytes(icon)
    info_path.write_bytes(plistlib.dumps(info))


def validate_bundle(app, values):
    version, build, public, icon, _ = values
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = {"CFBundleIdentifier": signing.BUNDLE, "CFBundleExecutable": "LessMeet",
                "CFBundlePackageType": "APPL", "LessMeetPackagingMode": "store",
                "CFBundleShortVersionString": version, "CFBundleVersion": build,
                "CFBundleIconFile": "LessMeet.icns", "LSMinimumSystemVersion": "15.0"}
    expected.update({prop: public[key] for key, prop in PUBLIC.items()})
    require(all(info.get(k) == v for k, v in expected.items()), "Store bundle metadata/configuration differs from approved inputs.")
    require(info.get("CFBundleURLTypes") == [{"CFBundleURLName": signing.BUNDLE,
                                             "CFBundleURLSchemes": [signing.BUNDLE]}], "Callback contract mismatch.")
    require((app / "Contents/Resources/LessMeet.icns").read_bytes() == icon, "Bundled icon differs from approved bytes.")
    for name in ("Clerk_ClerkKit.bundle", "RevenueCat_RevenueCat.bundle"):
        require((app / "Contents/Resources" / name).is_dir(), "Missing SDK resources.")
    require((app / "Contents/MacOS/LessMeet").is_file(), "Missing app executable.")


def verify_signed_app(app):
    requirement = 'anchor apple generic and identifier "' + signing.BUNDLE + '" and certificate leaf[subject.OU] = "' + signing.TEAM + '"'
    run(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "--test-requirement", requirement, app])
    profile = plistlib.loads(run(["/usr/bin/security", "cms", "-D", "-i", app / "Contents/embedded.provisionprofile"]))
    architectures = run(["/usr/bin/lipo", "-archs", app / "Contents/MacOS/LessMeet"]).decode().split()
    require(architectures and len(set(architectures)) == len(architectures)
            and set(architectures) <= {"arm64", "x86_64"}, "Unsupported executable architecture.")
    for arch in architectures:
        ent = plistlib.loads(run(["/usr/bin/codesign", "--display", "--arch", arch, "--entitlements", ":-", app]))
        with tempfile.TemporaryDirectory(prefix="lessmeet-app-cert-") as folder:
            prefix = Path(folder) / "cert"
            run(["/usr/bin/codesign", "--display", "--arch", arch, "--extract-certificates=" + str(prefix), app])
            der = Path(str(prefix) + "0").read_bytes()
        approved = signing.validate(profile, "store", hashlib.sha1(der).hexdigest(), signing.certificate_metadata(der))
        approved.update({"com.apple.security.app-sandbox": True, "com.apple.security.network.client": True,
                         "com.apple.security.device.audio-input": True})
        require(ent == approved, "Every architecture must have only the minimal approved entitlements.")


def installer_identity(output, requested):
    fingerprint = signing.select_identity(output, requested)
    names = re.findall(r'\b' + fingerprint + r'\s+"([^"\n]+)"', output, re.I)
    require(len(names) == 1 and re.fullmatch(r"(?:Mac Installer Distribution|3rd Party Mac Developer Installer): .+ \(" + signing.TEAM + r"\)", names[0]),
            "Installer requires this team's Mac Installer Distribution identity, not an app or Developer ID identity.")
    # productbuild documents a Common Name selector; prohibit duplicate names even
    # when the caller supplied a fingerprint (same-name renewals are common).
    signing.select_identity(output, names[0])
    return fingerprint, names[0]


def package(app, output, requested, values):
    app = app.resolve(strict=True)
    output = output.absolute()
    require(app.name == "LessMeet.app" and app.is_dir(), "Explicit LessMeet.app input required.")
    require(not output.exists() and not output.is_symlink(), "Output directory must be new; overwrites prohibited.")
    require(output.parent.resolve().is_dir() and app not in output.resolve().parents, "Output must be outside the input app with an existing parent.")
    # No symlink traversal into unowned data. Current app has no framework symlinks;
    # introducing frameworks requires reopening this narrow packaging policy.
    require(not any(p.is_symlink() for p in app.rglob("*")), "Symlink bundles need separate packaging review.")
    validate_bundle(app, values)
    require(requested and requested != "-", "Explicit installer signing identity required.")
    output.mkdir(mode=0o700)
    # Keep failures isolated and inspectable; never promote into dist or replace an app.
    with tempfile.TemporaryDirectory(prefix="work-", dir=output) as folder:
        work = Path(folder)
        snapshot = work / "LessMeet.app"
        shutil.copytree(app, snapshot)
        validate_bundle(snapshot, values)
        verify_signed_app(snapshot)
        fingerprint, name = installer_identity(run(["/usr/bin/security", "find-identity", "-v", "-p", "basic"]).decode(), requested)
        candidate = work / "LessMeet.pkg"
        run(["/usr/bin/productbuild", "--component", snapshot, "/Applications", "--sign", name, candidate])
        check = run(["/usr/sbin/pkgutil", "--check-signature", candidate]).decode()
        require("Status: signed by a certificate trusted by" in check
                and re.search(r"^\s*1\.\s+" + re.escape(name) + r"\s*$", check, re.M),
                "Installer signature must be trusted and match the selected installer identity.")
        # Recheck the exact app supplied to productbuild before retaining output.
        verify_signed_app(snapshot)
        validate_bundle(snapshot, values)
        result = {"schema": 1, "bundle": signing.BUNDLE, "team": signing.TEAM,
                  "version": values[0], "build": values[1], "pkg_sha256": digest(candidate.read_bytes()),
                  "approval_sha256": digest(json.dumps(values[4], sort_keys=True).encode()),
                  "limits": "Local packaging only; no upload acceptance, installation, runtime or publication proof."}
        # Hard-link provides exclusive creation; never overwrite a concurrent output.
        with (output / "validation.json").open("x") as file:
            json.dump(result, file, indent=2)
        os.link(candidate, output / "LessMeet.pkg")
    print("Isolated installer prepared and locally checked; NOT uploaded or release-accepted.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("inputs", help="Public inputs/icon checks only; no identity/profile access")
    stamp_parser = commands.add_parser("stamp", help="Internal build hook for unsigned store staging")
    stamp_parser.add_argument("app", type=Path)
    package_parser = commands.add_parser("package", help="Prepare signed pkg; separate signing authority required")
    package_parser.add_argument("--app", type=Path, required=True)
    package_parser.add_argument("--output-dir", type=Path, required=True)
    package_parser.add_argument("--installer-identity", required=True)
    args = parser.parse_args()
    values = inputs()
    if args.command == "stamp":
        stamp(args.app, values)
    elif args.command == "package":
        package(args.app, args.output_dir, args.installer_identity, values)
    else:
        print("Public input checks passed; approval assertions are NOT independently verified provider/branding evidence.")


if __name__ == "__main__":
    try:
        main()
    except Invalid as error:
        print("Store packaging failed: " + str(error), file=sys.stderr)
        sys.exit(1)
    except Exception:
        print("Store packaging failed: malformed/unreadable input or unavailable output; no release acceptance.", file=sys.stderr)
        sys.exit(1)
