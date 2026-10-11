#!/bin/bash
# Run the isolated macOS UI suite and retain Xcode's result bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --build-fixture ) ]]; then
  printf 'Usage: bash scripts/test-ui.sh [--build-fixture]\n' >&2
  exit 2
fi
python3 - <<'PY'
from pathlib import Path
import subprocess
root = Path.cwd()
binary = str(root / 'dist/offline-check/LessMeet.app/Contents/MacOS/LessMeet')
rows = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines()
for row in rows:
    parts = row.strip().split(None, 1)
    if len(parts) == 2 and (parts[1] == binary or parts[1].startswith(binary + ' ')):
        raise SystemExit('Offline app is already running. Release its UI owner before testing.')
PY
if [[ "${1:-}" == --build-fixture ]]; then
  exec bash scripts/build-app.sh offline-check
fi
mkdir -p .artifacts/verify-lessmeet
lock="$PWD/.artifacts/verify-lessmeet/ui-test.lock"
if ! mkdir "$lock" 2>/dev/null; then
  printf 'Another UI run may own %s. Check ownership before removing a stale lock.\n' "$lock" >&2
  exit 1
fi
trap 'rmdir "$lock"' EXIT
run_dir="$(mktemp -d "$PWD/.artifacts/verify-lessmeet/xcode.XXXXXX")"
printf 'Evidence: %s\n' "$run_dir"
xcodebuild -version > "$run_dir/xcode-version.txt"
git rev-parse HEAD > "$run_dir/base-commit.txt"
printf '%s\n' 'xcodebuild test -project Tests/UI/LessMeetUITests.xcodeproj -scheme LessMeetOfflineUI -destination platform=macOS -parallel-testing-enabled NO' > "$run_dir/command.txt"
set +e
xcodebuild test \
  -project Tests/UI/LessMeetUITests.xcodeproj \
  -scheme LessMeetOfflineUI \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -derivedDataPath "$PWD/.artifacts/verify-lessmeet/DerivedData" \
  -resultBundlePath "$run_dir/Tests.xcresult" \
  > "$run_dir/xcodebuild.log" 2>&1
result=$?
set -e
printf '%s\n' "$result" > "$run_dir/exit-code.txt"
python3 - "$run_dir" <<'PY'
import hashlib, json, subprocess, sys
from pathlib import Path
root = Path.cwd()
evidence = Path(sys.argv[1])
files = [root / 'dist/offline-check/LessMeet.app/Contents/MacOS/LessMeet',
         root / 'dist/offline-check/LessMeet.app/Contents/Info.plist',
         root / 'Tests/UI/OfflineAccountUITests.swift',
         root / 'Tests/UI/LessMeetUITests.xcodeproj/project.pbxproj']
(evidence / 'identity.json').write_text(json.dumps({str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files if p.is_file()}, indent=2)+'\n')
binary = str(files[0])
rows = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines()
remaining = [r for r in rows if len(p := r.strip().split(None, 1)) == 2 and (p[1] == binary or p[1].startswith(binary + ' '))]
(evidence / 'cleanup.txt').write_text('UNVERIFIED: fixture still running\n'+'\n'.join(remaining) if remaining else 'PASS: offline fixture is not running. Evidence retained.\n')
if remaining:
    print('UNVERIFIED: fixture still running; inspect the recorded PID before cleanup.', file=sys.stderr)
    sys.exit(1)
PY
if [[ -d "$run_dir/Tests.xcresult" ]]; then
  xcrun xcresulttool get test-results summary --path "$run_dir/Tests.xcresult" \
    > "$run_dir/summary.json" 2> "$run_dir/summary-error.txt" || true
fi
printf 'xcodebuild exit: %s\nResult: %s/Tests.xcresult\nLog: %s/xcodebuild.log\n' "$result" "$run_dir" "$run_dir"
exit "$result"
