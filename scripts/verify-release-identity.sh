#!/usr/bin/env bash
# Verifies that a built Herald.app is the RELEASE app, not a Debug/UI-test build (audit U6a,
# L3). Called by scripts/release.sh on the exported app; runnable by hand on any build:
#
#   scripts/verify-release-identity.sh <path/to/Herald.app>
#
# Fails (exit 1) unless ALL of these hold:
#   - CFBundleIdentifier is exactly com.wizemann.herald (Debug is com.wizemann.herald.debug);
#   - CFBundleURLTypes is exactly one entry whose name and ONLY scheme are com.wizemann.herald
#     (the OAuth callback scheme — HQBase clients registered by shipped copies depend on it);
#   - Contents/MacOS contains none of the Debug-only UI-test harness strings, and none of the
#     Debug-only identities (bundle id / callback scheme / Keychain namespace).
set -euo pipefail

RELEASE_ID="com.wizemann.herald"
APP="${1:?usage: verify-release-identity.sh <path/to/Herald.app>}"
PLIST="$APP/Contents/Info.plist"
BIN="$APP/Contents/MacOS/Herald"

fail() { printf '[ERR] release identity: %s\n' "$*" >&2; exit 1; }

[[ -f "$PLIST" ]] || fail "no Info.plist at $PLIST"
[[ -f "$BIN" ]] || fail "no executable at $BIN"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)"
[[ "$BUNDLE_ID" == "$RELEASE_ID" ]] || fail "CFBundleIdentifier is '$BUNDLE_ID', expected '$RELEASE_ID' (a Debug build?)"

# Exactly one URL type, exactly one scheme, both the release id.
/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:1' "$PLIST" >/dev/null 2>&1 \
  && fail "more than one CFBundleURLTypes entry"
URL_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLName' "$PLIST" 2>/dev/null || true)"
URL_SCHEME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$PLIST" 2>/dev/null || true)"
/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:1' "$PLIST" >/dev/null 2>&1 \
  && fail "more than one CFBundleURLSchemes entry"
[[ "$URL_NAME" == "$RELEASE_ID" ]] || fail "CFBundleURLName is '$URL_NAME', expected '$RELEASE_ID'"
[[ "$URL_SCHEME" == "$RELEASE_ID" ]] || fail "OAuth callback scheme is '$URL_SCHEME', expected '$RELEASE_ID'"

# The UI-test harness (Herald/UITestSupport, all #if DEBUG) and the Debug identities must not
# be in the shipped code. Every file in Contents/MacOS is scanned, not just the executable: a
# Debug build keeps its code in Herald.debug.dylib beside a stub. Literal (-F) matches over
# every printable string.
STRINGS="$(find "$APP/Contents/MacOS" -type f -exec strings -a {} +)"
for needle in HeraldUITest uitest. UITestHarness FakeHQBase \
              com.wizemann.herald.debug com.wizemann.herald.dev; do
  if grep -qF -- "$needle" <<<"$STRINGS"; then
    fail "Contents/MacOS contains '$needle' — Debug/UI-test code in a release build: $(grep -F -- "$needle" <<<"$STRINGS" | head -3 | tr '\n' ' ')"
  fi
done

printf '==> release identity OK: %s, URL scheme %s, no harness or Debug identity strings\n' "$BUNDLE_ID" "$URL_SCHEME"
