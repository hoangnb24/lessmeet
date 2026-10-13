"""Inert packaging boundaries. These fixtures do not compile or sign an app."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
BUNDLES = ("Clerk_ClerkKit.bundle",
           "LessMeet_LessMeet.bundle", "swift-transformers_Hub.bundle",
           "swift-crypto_Crypto.bundle")
NOTICES = ("Nemotron-LICENSE.txt", "Nemotron-NOTICE.txt", "OpenAI-Whisper-LICENSE.txt",
           "SOURCES.md", "WhisperKit-LICENSE.txt", "WhisperKit-NOTICES.txt",
           "speech-swift-LICENSE.txt")
METALLIB = b"synthetic metallib\x00fixture\n"


def inventory(path):
    return {str(p.relative_to(path)): p.read_bytes() for p in path.rglob("*") if p.is_file()}


def install(root, bin_name):
    """Install tools plus real clean local Git repos; never use operator Git config."""
    root = root.resolve()
    binary = root / "binary"
    binary.mkdir(exist_ok=True)
    (binary / "LessMeet").write_bytes(b"synthetic executable\n")
    for name in BUNDLES:
        bundle = binary / name
        (bundle / "nested").mkdir(parents=True, exist_ok=True)
        (bundle / "resource").write_bytes((name + "\n").encode())
        (bundle / "nested/payload").write_bytes(b"resource\x00bytes\n")
    shutil.copytree(ROOT / "Resources/ModelLicenses", root / "Resources/ModelLicenses")
    icon = root / "Resources/Artwork/lessmeet-v2/LessMeet.icns"
    icon.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ROOT / "Resources/Artwork/lessmeet-v2/LessMeet.icns", icon)
    env = {"PATH": os.environ["PATH"], "GIT_CONFIG_NOSYSTEM": "1",
           "GIT_CONFIG_GLOBAL": os.devnull, "GIT_TERMINAL_PROMPT": "0",
           "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
           "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
           "GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z"}
    pins = []
    for name in ("speech-swift", "mlx-swift"):
        repo = root / "fixture-checkouts" / name
        repo.mkdir(parents=True)
        (repo / "source").write_text("synthetic source\n")
        if name == "speech-swift":
            (repo / "scripts").mkdir()
            (repo / "scripts/build_mlx_metallib.sh").write_text('''#!/bin/bash
set -euo pipefail
[[ "$1" == release && "$MACOSX_DEPLOYMENT_TARGET" == 15.0 && "$MLX_METAL_LANGUAGE_VERSION" == 3.2 ]]
[[ -L "$BUILD_DIR/checkouts" ]]
printf 'shader %s\\n' "$BUILD_DIR" >> invoked
[[ "${TEST_SHADER_FAIL:-0}" == 0 ]] || exit 47
if [[ "${TEST_SHADER_EMPTY:-0}" == 1 ]]; then
  touch "$BUILD_DIR/release/mlx.metallib"
  exit 0
fi
printf 'synthetic metallib\\0fixture\\n' > "$BUILD_DIR/release/mlx.metallib"
''')
        for args in (("init", "-q"), ("add", "."), ("-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture")):
            subprocess.run(["git", "-C", str(repo), *args], env=env, check=True, capture_output=True)
        revision = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], env=env, text=True).strip()
        pins.append({"identity": name, "state": {"revision": revision}})
    (root / "Package.resolved").write_text(json.dumps({"version": 3, "pins": pins}))
    tool = f"#!{sys.executable}\nBUNDLES = {BUNDLES!r}\n" + '''import json, os, shutil, sys
from pathlib import Path
root = Path(os.environ["TEST_ROOT"])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps([name, *args]) + "\\n")
with (root / "invoked").open("a") as log:
    log.write(name + " " + " ".join(args) + "\\n")
if name == "xcrun":
    assert args == ["-sdk", "macosx", "metal", "--version"]
    sys.exit(int(os.environ.get("TEST_METAL_EXIT", "0")))
if name == "swift":
    assert args[0] == "build"
    assert "--disable-keychain" in args and "--disable-netrc" in args
    scratch = Path(args[args.index("--scratch-path") + 1])
    assert scratch.is_absolute() and root in scratch.parents
    if "--show-bin-path" in args:
        print(root / "binary")
    elif not (scratch / "checkouts").exists():
        shutil.copytree(root / "fixture-checkouts", scratch / "checkouts")
if name == "codesign":
    assert "--deep" not in args
    app = Path(args[-1])
    def inventory(path):
        return {str(p.relative_to(path)): p.read_bytes() for p in path.rglob("*") if p.is_file()}
    for bundle in BUNDLES:
        source = root / "binary" / bundle
        assert inventory(source) == inventory(app / "Contents/Resources" / source.name)
    assert inventory(root / "Resources/ModelLicenses") == inventory(app / "Contents/Resources/ModelLicenses")
    assert (app / "Contents/MacOS/mlx.metallib").read_bytes() == b"synthetic metallib\\x00fixture\\n"
    assert (app / "Contents/MacOS/mlx.metallib").is_symlink()
    assert os.readlink(app / "Contents/MacOS/mlx.metallib") == "../Resources/mlx.metallib"
    assert not (app / "Contents/Resources/mlx.metallib").is_symlink()
    assert (app / "Contents/Resources/mlx.metallib").read_bytes() == b"synthetic metallib\\x00fixture\\n"
    if any(part in ("sandbox-dev", "store", "testflight") for part in app.parts):
        assert (app / "Contents/embedded.provisionprofile").is_file()
    if "--sign" in args:
        sys.exit(int(os.environ.get("TEST_SIGN_EXIT", "0")))
'''
    for name in ("swift", "xcrun", "codesign"):
        path = root / bin_name / name
        path.write_text(tool)
        path.chmod(0o755)
    return {**env, "PATH": str(root / bin_name) + os.pathsep + env["PATH"],
            "TEST_ROOT": str(root), "PYTHONDONTWRITEBYTECODE": "1"}
