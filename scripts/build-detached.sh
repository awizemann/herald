#!/usr/bin/env bash
# Build Herald into isolated DerivedData and launch a decoupled dev copy (quits only its own
# previous instance). No arguments. Regenerates the Xcode project when project.yml is newer.
set -euo pipefail
cd "$(dirname "$0")/.."

# Debug builds use their own Keychain namespace (com.wizemann.herald.debug) and their own
# SwiftData cache (Application Support/Herald-Debug), so the dev copy and the release app can
# run side by side without sharing a refresh token or a store. Sign in once in the dev copy.

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
