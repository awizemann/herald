#!/usr/bin/env bash
# Build Herald into isolated DerivedData and launch a decoupled dev copy (quits only its own
# previous instance). No arguments. Regenerates the Xcode project when project.yml is newer.
set -euo pipefail
cd "$(dirname "$0")/.."

# Two Herald processes share ONE Keychain token item, and HQBase rotates the refresh token on
# every use with no reuse grace — a dev copy and the release app sign each other out.
RELEASE_APP="/Applications/Herald.app"
if [ -z "${HERALD_ALLOW_BOTH:-}" ] && pgrep -f "^$RELEASE_APP/Contents/MacOS/Herald" >/dev/null 2>&1; then
  echo "Refusing to launch: the release Herald at $RELEASE_APP is running."
  echo "Two Herald processes share one Keychain refresh token and will sign each other out."
  echo "Quit it first, or re-run with HERALD_ALLOW_BOTH=1 to override."
  exit 1
fi

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
