#!/usr/bin/env bash
# Runs Herald's XCUITest suite (scheme HeraldUITests) against the Debug-only UI-test
# mode (`-HeraldUITest <scenario>`, an in-process fake HQBase — never the network or
# the real Keychain).
#
# The tests TAKE OVER the mouse and keyboard while they run. The first run on a Mac
# asks (once) for Accessibility/Automation permission for the test runner; approve it
# in System Settings ▸ Privacy & Security, then run again.
#
# Usage: scripts/ui-tests.sh [extra xcodebuild args, e.g. -only-testing:HeraldUITests/SmokeTests]
set -euo pipefail

cd "$(dirname "$0")/.."

# XCUITest cannot bring an app to the front behind a locked screen: every launch then
# fails after ~60s with "Failed to activate application … (current state: Running
# Background)". Fail fast with the real reason instead.
if ioreg -n Root -d1 -a 2>/dev/null | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; then
    echo "The screen is locked — UI tests need an unlocked, logged-in GUI session. Unlock the Mac and rerun." >&2
    exit 3
fi

# The generated project lists files explicitly: regenerate when it is missing or older
# than the spec or any UI-test source.
if [[ ! -d Herald.xcodeproj ]] || [[ project.yml -nt Herald.xcodeproj/project.pbxproj ]] \
    || [[ -n "$(find HeraldUITests Herald -newer Herald.xcodeproj/project.pbxproj -name '*.swift' -print -quit 2>/dev/null)" ]]; then
    echo "==> xcodegen generate"
    xcodegen generate --quiet
fi

LOG_DIR="DerivedData/ui-tests-logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/ui-tests-$(date +%Y%m%d-%H%M%S).log"
RESULT="$LOG_DIR/$(basename "$LOG" .log).xcresult"

echo "==> xcodebuild test -scheme HeraldUITests (log: $LOG)"
set +e
xcodebuild \
    -project Herald.xcodeproj \
    -scheme HeraldUITests \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath DerivedData \
    -skipPackagePluginValidation \
    -resultBundlePath "$RESULT" \
    -test-timeouts-enabled YES \
    "$@" \
    test >"$LOG" 2>&1
STATUS=$?
set -e

echo
echo "==> Summary"
grep -E "^Test Case '.*' (passed|failed)|error: -\[|XCTAssert|Executed [0-9]+ tests?|\*\* TEST (SUCCEEDED|FAILED) \*\*|Testing failed|not authorized|Accessibility" "$LOG" | tail -60 || true
echo
echo "Full log:      $LOG"
echo "Result bundle: $RESULT"

if [[ $STATUS -ne 0 ]]; then
    echo "UI tests FAILED (xcodebuild exit $STATUS)" >&2
    exit "$STATUS"
fi
echo "UI tests passed."
