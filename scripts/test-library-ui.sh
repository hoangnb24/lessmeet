#!/bin/bash
# Test an existing approved fixture. Never package or replace the app.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 2 || "$1" != --app || "$2" != /* ]]; then
  printf 'Usage: bash scripts/test-library-ui.sh --app /absolute/path/LessMeet.app\n' >&2
  exit 2
fi
mkdir -p .artifacts/verify-lessmeet
run_dir="$(mktemp -d "$PWD/.artifacts/verify-lessmeet/library-xcode.XXXXXX")"
printf 'Evidence: %s\n' "$run_dir"
lock="$PWD/.artifacts/verify-lessmeet/ui-test.lock"
if ! mkdir "$lock" 2>/dev/null; then
  printf 'Another UI run may own %s. Do not remove its lock.\n' "$lock" >&2
  exit 1
fi
trap 'result=$?; printf "%s\n" "$result" > "$run_dir/exit-code.txt"; rmdir "$lock"' EXIT
app_path="$2"
python3 - "$app_path" "$run_dir" > "$run_dir/preflight.log" 2>&1 <<'PY'
import hashlib, json, plistlib, subprocess, sys
from pathlib import Path
app, evidence = Path(sys.argv[1]), Path(sys.argv[2])
if app.resolve() != app or app.suffix != '.app':
    raise SystemExit('Require a canonical absolute .app path; no symlink aliases.')
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if info.get('CFBundleIdentifier') != 'com.lessmeet.app.library-ui-check' or info.get('LessMeetPackagingMode') != 'library-ui-check' or info.get('CFBundleExecutable') != 'LessMeet':
    raise SystemExit('Refusing a non-Library fixture bundle.')
if any(k in info for k in ('ClerkPublishableKey', 'ConvexSiteURL', 'CFBundleURLTypes')):
    raise SystemExit('Refusing service-configured bundle.')
subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
# Inspect bundle metadata only. Do not read another app's data or credentials.
rows = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines()
for row in rows:
    parts = row.strip().split(None, 1)
    if len(parts) != 2 or '.app/Contents/MacOS/' not in parts[1]:
        continue
    bundle_path = Path(parts[1].split('.app/Contents/MacOS/', 1)[0] + '.app')
    try:
        running = plistlib.loads((bundle_path / 'Contents/Info.plist').read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException):
        continue
    if running.get('CFBundleIdentifier') == 'com.lessmeet.app.library-ui-check':
        raise SystemExit(f'Refusing existing Library fixture process: {row.strip()}')
files = [app / 'Contents/MacOS/LessMeet', app / 'Contents/Info.plist',
         Path('Tests/UI/LibraryNavigationUITests.swift'), Path('scripts/test-library-ui.sh'),
         Path('Tests/UI/LessMeetUITests.xcodeproj/project.pbxproj'),
         Path('Tests/UI/LessMeetUITests.xcodeproj/xcshareddata/xcschemes/LessMeetLibraryUI.xcscheme')]
identity = {'app': str(app), 'sha256': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}}
(evidence / 'identity.json').write_text(json.dumps(identity, indent=2) + '\n')
PY
xcodebuild -version > "$run_dir/xcode-version.txt"
git rev-parse HEAD > "$run_dir/base-commit.txt"
build=(xcodebuild build-for-testing -project Tests/UI/LessMeetUITests.xcodeproj
  -scheme LessMeetLibraryUI -destination platform=macOS -parallel-testing-enabled NO
  -disableAutomaticPackageResolution -derivedDataPath "$run_dir/DerivedData")
printf '%q ' "${build[@]}" > "$run_dir/build-command.txt"
"${build[@]}" > "$run_dir/build.log" 2>&1
python3 - "$run_dir" <<'PY'
import json, plistlib, sys
from pathlib import Path
evidence = Path(sys.argv[1])
identity = json.loads((evidence / 'identity.json').read_text())
plans = list((evidence / 'DerivedData/Build/Products').glob('*.xctestrun'))
if len(plans) != 1:
    raise SystemExit(f'Expected one test plan, found {len(plans)}')
plan = plistlib.loads(plans[0].read_bytes())
targets = [t for c in plan.get('TestConfigurations', []) for t in c.get('TestTargets', [])]
if not targets:
    targets = [v for k, v in plan.items() if k != '__xctestrun_metadata__' and isinstance(v, dict)]
if len(targets) != 1:
    raise SystemExit('Refusing an unexpected test target set')
target = targets[0]
target.setdefault('EnvironmentVariables', {}).update({
    'LIBRARY_UI_APP_PATH': identity['app'],
    'LIBRARY_UI_EXECUTABLE_SHA256': identity['sha256'][identity['app'] + '/Contents/MacOS/LessMeet']})
# Keep the plan beside build products so __TESTROOT__ remains valid.
plans[0].write_bytes(plistlib.dumps(plan))
(evidence / 'test-plan-path.txt').write_text(str(plans[0]) + '\n')
PY
plan_path="$(<"$run_dir/test-plan-path.txt")"
test=(xcodebuild test-without-building -xctestrun "$plan_path"
  -destination platform=macOS -parallel-testing-enabled NO
  -test-timeouts-enabled YES
  -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 180
  -resultBundlePath "$run_dir/Tests.xcresult")
printf '%q ' "${test[@]}" > "$run_dir/test-command.txt"
set +e
"${test[@]}" > "$run_dir/test.log" 2>&1
result=$?
set -e
if [[ -d "$run_dir/Tests.xcresult" ]]; then
  xcrun xcresulttool get test-results summary --path "$run_dir/Tests.xcresult" \
    > "$run_dir/summary.json" 2> "$run_dir/summary-error.txt" || true
fi
python3 - "$run_dir" <<'PY'
import json, subprocess, sys
from pathlib import Path
evidence = Path(sys.argv[1])
app = json.loads((evidence / 'identity.json').read_text())['app']
binary = app + '/Contents/MacOS/LessMeet'
rows = subprocess.check_output(['ps', '-axo', 'pid=,lstart=,command='], text=True).splitlines()
remaining = [row for row in rows if binary in row]
(evidence / 'cleanup.txt').write_text('UNVERIFIED: inspect owned process; no automatic kill.\n' + '\n'.join(remaining)
    if remaining else 'PASS: selected fixture process absent. Evidence retained.\n')
if remaining:
    raise SystemExit('Fixture remains; inspect identity before cleanup. No process was killed.')
PY
printf 'xcodebuild exit: %s\nResult: %s/Tests.xcresult\n' "$result" "$run_dir"
exit "$result"
