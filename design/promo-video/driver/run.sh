#!/bin/bash
# Usage: run.sh <app> <demo-dir> <testExplore|testRecordDemo>
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="$1"; dir="$2"; test="$3"
derived="$dir/DerivedData"
xcodebuild build-for-testing -project "$here/LessMeetDemoDriver.xcodeproj" -scheme LessMeetDemoDriver \
  -destination platform=macOS -derivedDataPath "$derived" > "$dir/driver-build.log" 2>&1
plan="$(ls "$derived"/Build/Products/*.xctestrun)"
python3 - "$plan" "$app" "$dir" <<'PY'
import plistlib, sys
path, app, d = sys.argv[1:]
plan = plistlib.loads(open(path, 'rb').read())
targets = [t for c in plan.get('TestConfigurations', []) for t in c.get('TestTargets', [])] or \
          [v for k, v in plan.items() if k != '__xctestrun_metadata__' and isinstance(v, dict)]
for t in targets:
    t.setdefault('EnvironmentVariables', {}).update(DEMO_APP_PATH=app, DEMO_DIR=d)
open(path, 'wb').write(plistlib.dumps(plan))
PY
set +e
xcodebuild test-without-building -xctestrun "$plan" -destination platform=macOS \
  -only-testing:"LessMeetDemoDriver/DemoDriverUITests/$test" > "$dir/driver-test.log" 2>&1
status=$?
set -e
grep -a $'^DEMOEVT\t' "$dir/driver-test.log" | cut -f2- > "$dir/events.tsv" || true
exit "$status"
