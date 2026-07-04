#!/usr/bin/env bash
#
# One-time Sparkle update-signing key setup.
#
# Generates an EdDSA key pair for signing auto-updates (if one doesn't already
# exist), stores the PRIVATE key in your login Keychain, and writes the PUBLIC
# key into Packaging/Info.plist (SUPublicEDKey). The private key never leaves
# your Keychain and is never committed; back it up somewhere safe, because
# losing it means you can no longer ship updates existing users will accept.
#
# Run once per machine/developer:
#   scripts/setup-sparkle-key.sh
#
# Idempotent: re-running keeps the existing key and just re-syncs the public key
# into Info.plist.

set -euo pipefail

export GIT_CONFIG_COUNT="${GIT_CONFIG_COUNT:-1}"
export GIT_CONFIG_KEY_0="${GIT_CONFIG_KEY_0:-safe.bareRepository}"
export GIT_CONFIG_VALUE_0="${GIT_CONFIG_VALUE_0:-all}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Packaging/Info.plist"

# Sparkle's tools ship in its resolved artifact bundle; a build resolves them.
SPARKLE_BIN="$(find "$ROOT/.build/artifacts" -type d -name bin -path '*sparkle*' 2>/dev/null | head -n1)"
if [[ -z "$SPARKLE_BIN" ]]; then
	echo "==> Resolving Sparkle (swift build) to get its signing tools"
	( cd "$ROOT" && swift build >/dev/null )
	SPARKLE_BIN="$(find "$ROOT/.build/artifacts" -type d -name bin -path '*sparkle*' 2>/dev/null | head -n1)"
fi
[[ -n "$SPARKLE_BIN" ]] || { echo "error: Sparkle tools not found under .build/artifacts" >&2; exit 1; }
GEN="$SPARKLE_BIN/generate_keys"

# generate_keys creates a key only if none exists; with an existing key it leaves
# it untouched and reports so. Either way, -p then prints the public key.
echo "==> Ensuring an EdDSA signing key exists (in your login Keychain)"
"$GEN" || true

PUBKEY="$("$GEN" -p 2>/dev/null | tr -d '[:space:]')"
[[ -n "$PUBKEY" ]] || { echo "error: could not read the public key from generate_keys" >&2; exit 1; }

echo "==> Writing SUPublicEDKey into $(basename "$PLIST")"
if /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBKEY" "$PLIST" 2>/dev/null; then :; else
	/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBKEY" "$PLIST"
fi

echo
echo "Done. SUPublicEDKey = $PUBKEY"
echo "The matching PRIVATE key lives in your login Keychain (item: 'Private key for signing"
echo "Sparkle updates'). Back it up now; it is unrecoverable and required for every future"
echo "update. Commit the Info.plist change, then release with scripts/release.sh."
