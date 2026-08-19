#!/usr/bin/env bash
#
# Herald release pipeline — local, manual, repeatable (t-8a1c0026). Ported from ShabuBox's
# scripts/release.sh and trimmed: no DMG, no vendored dylibs, no iCloud profile, no separate
# public repo — the appcast is published to THIS repo's gh-pages branch.
#
# REQUIRED ENV: APP_STATS_WRITE_KEY — the swift-stats write key baked into Info.plist. Secret:
# keep it in your password manager / Keychain, pass it per-invocation, and never put it in
# project.yml, an xcconfig in this repo, or a commit. Dev builds resolve it to "" (analytics off).
#
# Usage:
#   ./scripts/release.sh 0.1.0              # full: bump, archive, sign, notarize, staple,
#                                           # zip, appcast, GitHub release, tag, gh-pages push
#   (every form below also needs APP_STATS_WRITE_KEY in the environment)
#   ./scripts/release.sh 0.1.0 --dry-run    # everything EXCEPT notarize, publish, and tag
#   ./scripts/release.sh 0.1.0 --build 7    # pin CURRENT_PROJECT_VERSION instead of +1
#
# Release notes come from CHANGELOG.md — the "## [<VERSION>]" section is REQUIRED (preflight
# fails without it). It becomes the GitHub release body and, rendered to HTML beside the zip,
# the Sparkle update notes users see in "Check for Updates…". Write the notes, then release.
#
# ONE-TIME PREREQS (see README "Releasing"):
#   1. "Developer ID Application" certificate for team 3Q6X2L86C4 in the login Keychain.
#   2. A notarytool keychain profile:
#        xcrun notarytool store-credentials "herald-notary" \
#          --key <AuthKey_XXXX>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
#      (or reuse an existing one: NOTARY_PROFILE=<name> ./scripts/release.sh …)
#   3. The Sparkle EdDSA keypair under Keychain account "Herald":
#        ./scripts/sparkle-keys.sh      # then paste SUPublicEDKey into project.yml
#   4. gh authenticated (gh auth status) with write access to awizemann/herald.
#   5. brew install xcodegen
#
set -euo pipefail

# --- Xcode toolchain guard: build with a real Xcode.app, not the Command Line Tools. ---
if [ -z "${DEVELOPER_DIR:-}" ]; then
  case "$(xcode-select -p 2>/dev/null)" in
    */Xcode*.app/Contents/Developer) : ;;
    *) for _xc in /Applications/Xcode.app /Applications/Xcode-*.app /Applications/Xcode_*.app; do
         [ -x "$_xc/Contents/Developer/usr/bin/xcodebuild" ] && { export DEVELOPER_DIR="$_xc"; break; }
       done ;;
  esac
fi

# ---------- arg parsing ----------
VERSION=""
DRY_RUN=0
PINNED_BUILD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --build) shift; PINNED_BUILD="${1:?--build needs a number}" ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) printf '[ERR] unknown flag: %s\n' "$1" >&2; exit 1 ;;
    *) [[ -z "$VERSION" ]] && VERSION="$1" || { printf '[ERR] unexpected arg: %s\n' "$1" >&2; exit 1; } ;;
  esac
  shift
done
[[ -n "$VERSION" ]] || { printf 'usage: ./scripts/release.sh <marketing-version> [--dry-run] [--build N]\n' >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { printf '[ERR] version must look like 1.2.3, got: %s\n' "$VERSION" >&2; exit 1; }

# ---------- config ----------
TEAM_ID="3Q6X2L86C4"
SCHEME="Herald"
PROJECT="Herald.xcodeproj"
APP_NAME="Herald"
BUNDLE_ID="com.wizemann.herald"
NOTARY_PROFILE="${NOTARY_PROFILE:-herald-notary}"
SIGNING_IDENTITY="Developer ID Application"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-Herald}"
REPO="${REPO:-awizemann/herald}"
PAGES_BRANCH="${PAGES_BRANCH:-gh-pages}"
APPCAST_URL="https://awizemann.github.io/herald/appcast.xml"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_YML="$REPO_ROOT/project.yml"
EXPORT_OPTIONS="$REPO_ROOT/scripts/ExportOptions.plist"
ENTITLEMENTS="$REPO_ROOT/Herald/Herald.entitlements"
# Build outside the repo so nothing transient lands in git or gets signed.
BUILD_DIR="${TMPDIR:-/tmp}/herald-release-build"
RELEASE_DIR="$REPO_ROOT/releases/v${VERSION}"
NOTES_FILE="$RELEASE_DIR/RELEASE_NOTES.md"           # derived from CHANGELOG.md, not hand-written
CHANGELOG_SECTION="$REPO_ROOT/scripts/changelog-section.py"
OUT_ZIP="$RELEASE_DIR/${APP_NAME}-${VERSION}.zip"
DOWNLOAD_PREFIX="https://github.com/${REPO}/releases/download/v${VERSION}/"

# ---------- helpers ----------
log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*" >&2; }
skip() { printf '\033[1;35m[dry-run] skipping: %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[ERR] %s\033[0m\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1 (brew install $1)"; }

cd "$REPO_ROOT"

# ---------- preflight ----------
log "Preflight$([[ $DRY_RUN -eq 1 ]] && printf ' (dry run)')"
python3 "$CHANGELOG_SECTION" "$VERSION" >/dev/null 2>&1 \
  || die "CHANGELOG.md has no '## [$VERSION]' section — write the release notes first (see CHANGELOG.md header)"
require_cmd xcodebuild; require_cmd xcrun; require_cmd ditto; require_cmd gh; require_cmd xcodegen; require_cmd git

# The swift-stats write key is a SECRET: it lives only in the environment for this invocation and
# is baked into Info.plist by the archive below (Herald/Info.plist holds $(APP_STATS_WRITE_KEY),
# which resolves to the empty string for every dev build). It must never be written to project.yml,
# an xcconfig, or any file in this repo, and it must never be printed — so nothing here echoes it.
[[ -n "${APP_STATS_WRITE_KEY:-}" ]] || die "APP_STATS_WRITE_KEY is not set (or is empty).
Release builds must bake the swift-stats write key into Info.plist. Supply it for this run only:
  APP_STATS_WRITE_KEY=\"\$(<your secret store>)\" ./scripts/release.sh $VERSION
Never commit it to project.yml, an xcconfig, or any file in this repo."

# The entitlements file must parse — a malformed plist fails the archive late and cryptically,
# and the two Sparkle mach-lookup exceptions are what let the sandboxed installer run at all.
plutil -lint "$ENTITLEMENTS" >/dev/null || die "$ENTITLEMENTS is not a valid plist"
/usr/libexec/PlistBuddy -c 'Print :com.apple.security.temporary-exception.mach-lookup.global-name:0' "$ENTITLEMENTS" \
  | grep -q -- '-spks' || die "Sparkle mach-lookup exception ($BUNDLE_ID-spks) missing from $ENTITLEMENTS — sandboxed updates would fail to install"

# Clean tree, but ONLY the build inputs: the Memophant-managed tiers (.memory/, tasks/,
# documents/, TASKS.md) are dirty here by design, so asserting the whole tree clean would make
# releases impossible.
BUILD_PATHS=(Herald HeraldKit HeraldTests project.yml scripts .github/workflows)
DIRTY="$(git status --porcelain -- "${BUILD_PATHS[@]}" || true)"
[[ -z "$DIRTY" ]] || die "build inputs not committed (commit or stash first):
$DIRTY"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
  [[ "${ALLOW_ANY_BRANCH:-0}" == "1" ]] || die "not on main (currently $BRANCH; set ALLOW_ANY_BRANCH=1 to override)"
  warn "releasing from $BRANCH (ALLOW_ANY_BRANCH=1)"
fi

git tag --list "v${VERSION}" | grep -q . && die "tag v${VERSION} already exists — bump the version or delete the tag"

security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY" \
  || die "'$SIGNING_IDENTITY' certificate not in the login Keychain — download it from developer.apple.com (team $TEAM_ID) and double-click to install"

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null 2>&1 \
  || die "notarytool profile '$NOTARY_PROFILE' not set up. Create it once:
  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --key <AuthKey_XXXX>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
(or reuse another with NOTARY_PROFILE=<name>)"

gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"

# Sparkle's tools live inside the resolved SPM checkout, which only exists after a build.
# Prefer THIS repo's DerivedData: another project's checkout may be a different Sparkle
# version, and generate_appcast must match the framework we ship.
find_sparkle_bin() {
  local root hit
  for root in "$REPO_ROOT/DerivedData" "$HOME/Library/Developer/Xcode/DerivedData"; do
    [[ -d "$root" ]] || continue
    hit="$(find "$root" -path '*sparkle*/bin/generate_appcast' -type f 2>/dev/null | head -n1)"
    [[ -n "$hit" ]] && { dirname "$hit"; return; }
  done
}
SPARKLE_BIN="$(find_sparkle_bin)"
[[ -x "$SPARKLE_BIN/generate_appcast" && -x "$SPARKLE_BIN/generate_keys" ]] \
  || die "Sparkle tools not found — build once so the package resolves:
  xcodegen generate && xcodebuild -project $PROJECT -scheme $SCHEME -destination 'platform=macOS' -derivedDataPath DerivedData -skipPackagePluginValidation build
then re-run."

# The public key baked into the app MUST match the private key that will sign the update, or
# every installed copy rejects the release.
SOURCE_PUBKEY="$(awk -F': ' '/^ *SUPublicEDKey:/ {print $2; exit}' "$PROJECT_YML" | tr -d ' "')"
[[ -n "$SOURCE_PUBKEY" ]] || die "SUPublicEDKey missing from $PROJECT_YML"
[[ "$SOURCE_PUBKEY" == *PLACEHOLDER* ]] && die "SUPublicEDKey in $PROJECT_YML is still the placeholder.
Mint the keypair once and paste the printed line into project.yml:
  ./scripts/sparkle-keys.sh"
KEYCHAIN_PUBKEY="$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null | grep -oE '[A-Za-z0-9+/]{43}=' | head -1 || true)"
[[ -n "$KEYCHAIN_PUBKEY" ]] || die "no Sparkle key in the Keychain under account '$SPARKLE_ACCOUNT'.
Mint one (./scripts/sparkle-keys.sh) or restore your backup:
  $SPARKLE_BIN/generate_keys --account $SPARKLE_ACCOUNT -f <private-key-file>"
[[ "$SOURCE_PUBKEY" == "$KEYCHAIN_PUBKEY" ]] || die "Sparkle key mismatch — refusing to release.
  project.yml SUPublicEDKey:            $SOURCE_PUBKEY
  Keychain (account $SPARKLE_ACCOUNT):  $KEYCHAIN_PUBKEY
Releasing now would ship a signature no installed copy can verify."
log "Sparkle keypair OK ($SOURCE_PUBKEY) under account '$SPARKLE_ACCOUNT'"

# ---------- version bump (project.yml is the xcodegen source of truth) ----------
CUR_MV="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' "$PROJECT_YML")"
if [[ "$CUR_MV" == "$VERSION" ]]; then
  log "Version already $VERSION — resume mode (no bump). Regenerating project."
  # env -u: xcodegen must never see the write key, so it cannot end up in the generated project.
  env -u APP_STATS_WRITE_KEY xcodegen generate
else
  CUR_BUILD="$(awk -F': ' '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' "$PROJECT_YML" | tr -d ' "')"
  NEW_BUILD="${PINNED_BUILD:-$((CUR_BUILD + 1))}"
  log "Bump $CUR_MV -> $VERSION (CFBundleVersion $NEW_BUILD)"
  sed -i '' -E "s/MARKETING_VERSION: \"[0-9][0-9.]*\"/MARKETING_VERSION: \"${VERSION}\"/" "$PROJECT_YML"
  sed -i '' -E "s/CURRENT_PROJECT_VERSION: \"?[0-9]+\"?/CURRENT_PROJECT_VERSION: ${NEW_BUILD}/" "$PROJECT_YML"
  env -u APP_STATS_WRITE_KEY xcodegen generate
  # Guard against a silent no-op sed: confirm the EFFECTIVE setting actually changed.
  ACTUAL_MV="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null | awk -F' = ' '/ MARKETING_VERSION / {print $2; exit}')"
  [[ "$ACTUAL_MV" == "$VERSION" ]] || die "MARKETING_VERSION didn't take (effective: $ACTUAL_MV) — check $PROJECT_YML"
  mkdir -p "$RELEASE_DIR"
  if [[ $DRY_RUN -eq 1 ]]; then
    skip "commit of the version bump (project.yml is edited in your working tree — 'git checkout project.yml' to undo)"
  else
    git add "$PROJECT_YML"
    git commit -m "chore(release): v${VERSION}"
  fi
fi

# ---------- archive + export ----------
log "Clean build directory"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR" "$RELEASE_DIR"
ARCHIVE="$BUILD_DIR/${APP_NAME}.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/${APP_NAME}.app"
NOTARIZE_ZIP="$BUILD_DIR/${APP_NAME}-notarize.zip"

# -derivedDataPath keeps this out of the shared DerivedData Xcode may have open (two build
# systems on one DerivedData corrupts build.db).
# Hand the write key to the archive through a private xcconfig in a 0600 temp dir OUTSIDE the
# repo, deleted on exit. Why not `xcodebuild … APP_STATS_WRITE_KEY=…`: xcodebuild echoes its own
# argv under "Command line invocation:" at the top of every build log, which would print the
# secret to the terminal and into any CI transcript. An -xcconfig path is inert in the log; only
# the file holds the value, and it never exists inside the repo.
STATS_XCCONFIG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/herald-stats-key.XXXXXX")"
chmod 700 "$STATS_XCCONFIG_DIR"
STATS_XCCONFIG="$STATS_XCCONFIG_DIR/stats.xcconfig"
( umask 077; printf 'APP_STATS_WRITE_KEY = %s\n' "$APP_STATS_WRITE_KEY" > "$STATS_XCCONFIG" )
trap 'rm -rf "$STATS_XCCONFIG_DIR"' EXIT

log "Archive (Release, arm64)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" -destination "generic/platform=macOS" \
  -derivedDataPath "$BUILD_DIR/DerivedData" -skipPackagePluginValidation \
  -xcconfig "$STATS_XCCONFIG" \
  archive

log "Export signed .app (Developer ID)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS"
[[ -d "$APP" ]] || die "exported app not found at $APP"

log "Verify signature (incl. embedded Sparkle.framework + its XPC services)"
codesign --verify --deep --strict --verbose=2 "$APP"

# The update is worthless if the shipped app doesn't carry the matching public key, and the
# sandboxed installer can't run without the mach-lookup exceptions surviving the re-seal.
BUILT_PUBKEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$BUILT_PUBKEY" == "$SOURCE_PUBKEY" ]] || die "built app SUPublicEDKey ($BUILT_PUBKEY) != project.yml ($SOURCE_PUBKEY)"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - - | grep -q -- "-spks" \
  || die "Sparkle mach-lookup entitlement missing from the exported app — sandboxed updates would fail to install"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - - | grep -q "app-sandbox" \
  || die "app-sandbox entitlement missing — the Release build must be sandboxed"

# The analytics write key must have been substituted into the shipped Info.plist. A build that
# ships the literal $(APP_STATS_WRITE_KEY) — or an empty value — silently disables usage
# reporting for every user of this release, so fail loudly here. Never print the value itself:
# compare, and report only which failure mode it was. (Runs in dry-run too — same build.)
BUILT_STATS_KEY="$(/usr/libexec/PlistBuddy -c 'Print :HeraldStatsWriteKey' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ -n "$BUILT_STATS_KEY" ]] \
  || die "HeraldStatsWriteKey missing or empty in the exported app's Info.plist — check that Herald/Info.plist still carries the \$(APP_STATS_WRITE_KEY) entry"
[[ "$BUILT_STATS_KEY" != '$(APP_STATS_WRITE_KEY)' ]] \
  || die "HeraldStatsWriteKey in the exported app is still the literal build-setting placeholder — the xcconfig did not reach the archive"
[[ "$BUILT_STATS_KEY" == "$APP_STATS_WRITE_KEY" ]] \
  || die "HeraldStatsWriteKey in the exported app does not match APP_STATS_WRITE_KEY (values withheld) — stale archive or an overriding build setting?"
log "HeraldStatsWriteKey baked into the exported app (value withheld)"

# Apple requires the privacy manifest inside the shipped bundle; it is a resource, so a project
# regeneration that drops it fails App Review / privacy reporting silently.
[[ -f "$APP/Contents/Resources/PrivacyInfo.xcprivacy" ]] \
  || die "PrivacyInfo.xcprivacy missing from $APP/Contents/Resources — check that project.yml still lists it as a Herald resource"

# ---------- notarize + staple ----------
if [[ $DRY_RUN -eq 1 ]]; then
  skip "notarization + stapling"
else
  log "Submit to notarytool (blocking)"
  xattr -cr "$APP"
  ditto -c -k --keepParent --norsrc "$APP" "$NOTARIZE_ZIP"
  # notarytool --wait exits 0 even on a terminal "Invalid" status, so gate explicitly.
  xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m 2>&1 \
    | tee "$BUILD_DIR/notarize.log"
  grep -q "status: Accepted" "$BUILD_DIR/notarize.log" \
    || die "notarization did not reach 'status: Accepted' (see $BUILD_DIR/notarize.log)"

  log "Staple + validate"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose "$APP"
fi

# ---------- package ----------
# Issue #2 (bermanto): plain `ditto -c -k` stores every extended attribute (quarantine,
# Finder info, provenance) as an AppleDouble "._*" entry — 131 of them in v0.1.0/v0.1.1.
# `ditto -x` silently folds those back into xattrs, so OUR verification passed, but
# Finder/`unzip` leave them as real files inside the bundle and `codesign --verify
# --strict` then reports "added files" in Sparkle's installer. Fix: strip xattrs from
# the signed app first, archive with --norsrc (no resource forks / AppleDouble at all),
# and verify with `unzip`, the reader users actually hit.
log "Package $(basename "$OUT_ZIP")"
rm -f "$OUT_ZIP"
xattr -cr "$APP"
ditto -c -k --keepParent --norsrc "$APP" "$OUT_ZIP"
APPLEDOUBLE_COUNT="$(unzip -l "$OUT_ZIP" | awk '{print $4}' | grep -c '/\._' || true)"
[[ "$APPLEDOUBLE_COUNT" == "0" ]] || die "zip contains $APPLEDOUBLE_COUNT AppleDouble (._*) entries — packaging regression"

log "Post-package verification (on the ACTUAL distribution zip, extracted with unzip)"
VERIFY_DIR="$(mktemp -d)"
unzip -q "$OUT_ZIP" -d "$VERIFY_DIR"
codesign --verify --strict --deep --verbose=2 "$VERIFY_DIR/${APP_NAME}.app" || die "codesign verify failed on the packaged zip (unzip extraction)"
if [[ $DRY_RUN -eq 0 ]]; then
  spctl --assess --type execute --verbose "$VERIFY_DIR/${APP_NAME}.app" || die "spctl assess failed on the packaged zip"
fi
rm -rf "$VERIFY_DIR"

# ---------- appcast ----------
# generate_appcast scans RELEASE_DIR, signs each archive with the "$SPARKLE_ACCOUNT" private
# key from the Keychain, reads the version out of the .app, and writes appcast.xml.
# --download-url-prefix points the enclosure at this version's GitHub release asset; only the
# small appcast.xml is served from Pages, never the binary.
# Release notes for the appcast: generate_appcast embeds a .html file that shares the
# archive's base name, so the update prompt shows this version's CHANGELOG section.
python3 "$CHANGELOG_SECTION" "$VERSION" --html > "${OUT_ZIP%.zip}.html" \
  || die "could not render CHANGELOG.md section for $VERSION"
log "generate_appcast (account: $SPARKLE_ACCOUNT)"
"$SPARKLE_BIN/generate_appcast" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  -o "$RELEASE_DIR/appcast.xml" \
  "$RELEASE_DIR" || die "generate_appcast failed"
[[ -f "$RELEASE_DIR/appcast.xml" ]] || die "appcast.xml was not produced"

# ---------- publish ----------
if [[ $DRY_RUN -eq 1 ]]; then
  skip "git tag v${VERSION}, gh release create, and the $PAGES_BRANCH appcast push"
  log "Dry run complete. Artifacts:"
  log "  app:     $APP"
  log "  zip:     $OUT_ZIP"
  log "  appcast: $RELEASE_DIR/appcast.xml"
  exit 0
fi

log "Push $BRANCH + tag v${VERSION}"
git push origin "$BRANCH"
git tag "v${VERSION}"
git push origin "v${VERSION}"

log "Create GitHub release ($REPO)"
mkdir -p "$RELEASE_DIR"
python3 "$CHANGELOG_SECTION" "$VERSION" > "$NOTES_FILE" || die "could not extract CHANGELOG.md section for $VERSION"
gh release create "v${VERSION}" -R "$REPO" --latest \
  --title "${APP_NAME} v${VERSION}" --notes-file "$NOTES_FILE" "$OUT_ZIP"

# Publish appcast.xml to gh-pages via a throwaway worktree — never checks out the branch in
# the working tree, so an interrupted release can't leave the repo on the wrong branch.
log "Publish appcast.xml to $PAGES_BRANCH (served at $APPCAST_URL)"
PAGES_WT="$BUILD_DIR/gh-pages"
rm -rf "$PAGES_WT"
if git ls-remote --exit-code --heads origin "$PAGES_BRANCH" >/dev/null 2>&1; then
  git fetch origin "$PAGES_BRANCH"
  git worktree add "$PAGES_WT" -B "$PAGES_BRANCH" "origin/$PAGES_BRANCH"
else
  log "$PAGES_BRANCH does not exist — creating it as an orphan branch"
  git worktree add --detach "$PAGES_WT"
  git -C "$PAGES_WT" checkout --orphan "$PAGES_BRANCH"
  git -C "$PAGES_WT" rm -rf . >/dev/null 2>&1 || true
  # .nojekyll so Pages serves the files verbatim (no Jekyll build, no underscore filtering).
  : > "$PAGES_WT/.nojekyll"
fi
cp "$RELEASE_DIR/appcast.xml" "$PAGES_WT/appcast.xml"
find "$RELEASE_DIR" -name '*.delta' -exec cp {} "$PAGES_WT/" \; 2>/dev/null || true
(
  cd "$PAGES_WT"
  git add -A
  if git diff --cached --quiet; then
    log "appcast.xml unchanged — nothing to publish"
  else
    git commit -m "appcast: Herald v${VERSION}"
    git push origin "$PAGES_BRANCH"
  fi
)
git worktree remove --force "$PAGES_WT"

log "Release v${VERSION} complete"
log "  Download: ${DOWNLOAD_PREFIX}${APP_NAME}-${VERSION}.zip"
log "  Appcast:  $APPCAST_URL"
log "  Verify:   curl -sIL $APPCAST_URL | head -3"
