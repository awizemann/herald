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
#
# SAFETY (audit U6a / H1): the suite must only ever drive the Debug build, whose bundle id is
# com.wizemann.herald.debug — a different app from the release Herald, with its own Keychain
# namespace, container and callback scheme. So this script
#   - refuses extra args that could change WHAT is built or run (-configuration, -scheme,
#     -project, -workspace, -derivedDataPath, -xctestrun, -xcconfig, NAME=value build settings);
#   - builds first (build-for-testing) and refuses to run unless the built Herald.app's
#     CFBundleIdentifier is com.wizemann.herald.debug;
#   - builds into its OWN DerivedData (DerivedData-UITests), so scripts/build-detached.sh's
#     `pkill` of its dev copy (DerivedData/…/Herald.app) can never kill a UI-test run and the
#     two never race on one build.db.
# The launch helper (HeraldUITests/Support/HeraldLaunch.swift) is the third guard: a launched
# app that does not show the harness's `uitest.status` is terminated before any test step.
# Note: XCUIApplication.launch() terminates a running instance of the SAME bundle id first —
# i.e. a dev copy launched by build-detached.sh (never the release app).
set -euo pipefail

cd "$(dirname "$0")/.."

DEBUG_BUNDLE_ID="com.wizemann.herald.debug"
DD="DerivedData-UITests"
APP="$DD/Build/Products/Debug/Herald.app"

for arg in "$@"; do
    case "$arg" in
        -configuration|-configuration=*|-scheme|-scheme=*|-project|-project=*|-workspace|-workspace=*|\
        -derivedDataPath|-derivedDataPath=*|-xctestrun|-xctestrun=*|-xcconfig|-xcconfig=*)
            echo "ui-tests.sh: refusing '$arg' — the UI suite only runs the Debug build of scheme HeraldUITests (see the header)." >&2
            exit 2 ;;
    esac
    if [[ "$arg" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        echo "ui-tests.sh: refusing build-setting override '$arg' — it could change the app's identity." >&2
        exit 2
    fi
done

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

COMMON=(
    -project Herald.xcodeproj
    -scheme HeraldUITests
    -configuration Debug
    -destination 'platform=macOS'
    -derivedDataPath "$DD"
    -skipPackagePluginValidation
)

echo "==> xcodebuild build-for-testing -scheme HeraldUITests (log: $LOG)"
if ! xcodebuild "${COMMON[@]}" build-for-testing >"$LOG" 2>&1; then
    grep -E "error:|\*\* .* FAILED \*\*" "$LOG" | tail -30 >&2 || true
    echo "UI-test build FAILED (full log: $LOG)" >&2
    exit 65
fi

BUILT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$BUILT_ID" != "$DEBUG_BUNDLE_ID" ]]; then
    echo "ui-tests.sh: the built app's bundle id is '$BUILT_ID', not '$DEBUG_BUNDLE_ID' — refusing to run UI tests against it." >&2
    exit 4
fi
echo "==> built $APP ($BUILT_ID)"

echo "==> xcodebuild test-without-building -scheme HeraldUITests"
set +e
xcodebuild "${COMMON[@]}" \
    -resultBundlePath "$RESULT" \
    -test-timeouts-enabled YES \
    "$@" \
    test-without-building >>"$LOG" 2>&1
STATUS=$?
set -e

echo
echo "==> Summary"
grep -E "^Test Case '.*' (passed|failed)|error: -\[|XCTAssert|Executed [0-9]+ tests?|\*\* TEST( EXECUTE)? (SUCCEEDED|FAILED) \*\*|Testing failed|not authorized|Accessibility" "$LOG" | tail -60 || true
echo
echo "Full log:      $LOG"
echo "Result bundle: $RESULT"

if [[ $STATUS -ne 0 ]]; then
    echo "UI tests FAILED (xcodebuild exit $STATUS)" >&2
    exit "$STATUS"
fi
echo "UI tests passed."
