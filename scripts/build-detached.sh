#!/usr/bin/env bash
# Build Herald into isolated DerivedData and launch a decoupled dev copy (quits only its own
# previous instance). No arguments. Regenerates the Xcode project when project.yml is newer.
set -euo pipefail
cd "$(dirname "$0")/.."

# The dev copy is a DIFFERENT app from the release Herald (audit U6a): Debug builds have their
# own bundle id (com.wizemann.herald.debug) — hence their own sandbox container, preferences,
# attachment scratchpad, notification identity and OAuth callback scheme — plus their own
# Keychain namespace (com.wizemann.herald.dev) and SwiftData cache (Herald-Debug). So it runs
# side by side with /Applications/Herald.app without sharing a refresh token, a store or a
# callback. Sign in once in the dev copy (it registers its own OAuth client).
#
# The pkill below matches only THIS DerivedData's executable path. scripts/ui-tests.sh builds
# into DerivedData-UITests, so this can never kill a UI-test run; the release app lives
# elsewhere and is never touched. (Running the UI suite, conversely, quits a running dev copy:
# XCUIApplication terminates any instance of the same bundle id before launching.)

if [ ! -d Herald.xcodeproj ] || [ project.yml -nt Herald.xcodeproj/project.pbxproj ]; then
  xcodegen generate
fi
DD="$PWD/DerivedData"
xcodebuild -project Herald.xcodeproj -scheme Herald -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$DD" -skipPackagePluginValidation build 2>&1 | grep -E "error:|warning: |BUILD" || true
APP="$DD/Build/Products/Debug/Herald.app"
[ -d "$APP" ] || { echo "build failed"; exit 1; }
pkill -f "$APP/Contents/MacOS/Herald" 2>/dev/null || true
open -n "$APP"
echo "launched $APP"
