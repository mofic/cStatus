#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/dist/cStatus.app/Contents/MacOS/cStatus"
if [ ! -x "$app" ]; then
    bash scripts/build-app.sh
fi
report="$PWD/.build/ui-smoke.json"
rm -f "$report"
"$app" --smoke-test --report "$report"
/usr/bin/python3 - "$report" <<'PY'
import json, sys
with open(sys.argv[1]) as file:
    report = json.load(file)
for key in ('collapsedPanelVisible', 'expandedPanelVisible', 'bubbleVisible', 'panelDoesNotActivateOnHover'):
    assert report.get(key) is True, (key, report)
assert report['screenCount'] >= 1
print('Native window smoke checks passed:', report)
PY
