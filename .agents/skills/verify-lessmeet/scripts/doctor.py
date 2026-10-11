#!/usr/bin/env python3
"""Read-only identity and process check for the offline verification bundle."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys

repo = Path(__file__).resolve().parents[4]
bundle = repo / 'dist/offline-check/LessMeet.app'
binary = bundle / 'Contents/MacOS/LessMeet'
plist_path = bundle / 'Contents/Info.plist'
try:
    plist = plistlib.loads(plist_path.read_bytes())
    assert plist['CFBundleIdentifier'] == 'com.lessmeet.app.offline-check', 'Wrong bundle ID'
    assert not any(plist.get(k) for k in ('ClerkPublishableKey', 'ConvexSiteURL', 'CFBundleURLTypes')), 'Service configuration present'
    subprocess.run(['codesign', '--verify', '--strict', str(bundle)], check=True, capture_output=True)
    rows = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines()
    pids = [int(parts[0]) for row in rows if len(parts := row.strip().split(None, 1)) == 2 and parts[1] == str(binary)]
    assert len(pids) == 1, f'Expected one exact running executable; found {len(pids)}'
    started = subprocess.check_output(['ps', '-p', str(pids[0]), '-o', 'lstart='], text=True).strip()
    print(json.dumps({'bundle': str(bundle), 'bundleID': plist['CFBundleIdentifier'], 'pid': pids[0], 'started': started,
        'executableSHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
        'plistSHA256': hashlib.sha256(plist_path.read_bytes()).hexdigest(), 'signature': 'PASS'}, indent=2))
except (OSError, AssertionError, KeyError, ValueError, subprocess.CalledProcessError) as error:
    print(f'UNVERIFIED: {error}', file=sys.stderr)
    sys.exit(1)
