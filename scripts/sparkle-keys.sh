#!/usr/bin/env bash
#
# Herald — Sparkle EdDSA keypair, one-shot setup (t-8a1c0026).
#
# Run this ONCE, on the machine that cuts releases:
#
#   ./scripts/sparkle-keys.sh
#
# It mints (or reads back) the ed25519 keypair Sparkle uses to sign updates, under the
# NAMESPACED login-Keychain account "Herald" — isolated from the other apps' keys — and
# prints the PUBLIC half plus the exact project.yml line to paste.
#
# THE PRIVATE KEY LIVES ONLY IN THE KEYCHAIN. This script never prints it, never writes it
# to disk, and never puts it in the repo. If the machine dies without a Keychain backup the
# key is gone and every installed copy stops accepting updates — export a backup ONCE,
# by hand, into a password manager:
#
#   "$SPARKLE_BIN/generate_keys" --account Herald -x /path/to/herald-sparkle-private.key
#   # …store it, then shred the file. Restore later with: generate_keys --account Herald -f <file>
#
set -euo pipefail

SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-Herald}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m[ERR] %s\033[0m\n' "$*" >&2; exit 1; }

# Sparkle ships generate_keys inside the resolved SPM checkout, which only exists after the
# package has been fetched by a build.
SPARKLE_BIN_DIR=""
for _root in "$REPO_ROOT/DerivedData" "$HOME/Library/Developer/Xcode/DerivedData"; do
  [[ -d "$_root" ]] || continue
  _hit="$(find "$_root" -path '*sparkle*/bin/generate_keys' -type f 2>/dev/null | head -n1)"
  [[ -n "$_hit" ]] && { SPARKLE_BIN_DIR="$(dirname "$_hit")"; break; }
done
[[ -x "$SPARKLE_BIN_DIR/generate_keys" ]] || die "generate_keys not found — build once so the Sparkle package resolves:
  xcodegen generate && xcodebuild -project Herald.xcodeproj -scheme Herald -destination 'platform=macOS' -derivedDataPath DerivedData -skipPackagePluginValidation build
then re-run this script."

log "Sparkle tools: $SPARKLE_BIN_DIR"

# generate_keys is idempotent: with an existing key under this account it reports that and
# leaves it alone. Its output can mention the private key, so it is not echoed here.
"$SPARKLE_BIN_DIR/generate_keys" --account "$SPARKLE_ACCOUNT" >/dev/null 2>&1 || true

PUBKEY="$("$SPARKLE_BIN_DIR/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null \
  | grep -oE '[A-Za-z0-9+/]{43}=' | head -1 || true)"
[[ -n "$PUBKEY" ]] || die "could not read a public key back for account '$SPARKLE_ACCOUNT' — check Keychain Access for an 'Sparkle' / '$SPARKLE_ACCOUNT' item"

cat <<EOF

$(log "Public key for account '$SPARKLE_ACCOUNT' (safe to commit — it only VERIFIES)")

  $PUBKEY

Paste this line into project.yml, under targets.Herald.info.properties, replacing the
placeholder:

  SUPublicEDKey: $PUBKEY

Then: xcodegen generate  (and commit project.yml)

The PRIVATE key stays in your login Keychain under account "$SPARKLE_ACCOUNT". It is not in
this repo and must never be. Back it up once (see the header of this script) — without it you
cannot ever ship another update to installed copies.
EOF
