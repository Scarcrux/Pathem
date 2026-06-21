#!/usr/bin/env bash
#
# Package Pathom into a macOS .app bundle.
#
# Defaults to a universal (arm64 + x86_64), ad-hoc-signed bundle that runs
# locally. To produce a distributable build, set the environment variables below;
# each step is skipped unless its credentials are present, so the script is safe
# to run as-is.
#
#   ARCHS            architectures to build, space separated
#                    (default: "arm64 x86_64"; set "arm64" for a faster local build)
#   DEVELOPER_ID     "Developer ID Application: Name (TEAMID)" to sign for release
#                    with Hardened Runtime (required before notarization)
#   NOTARY_PROFILE   a notarytool keychain profile name; if set together with
#                    DEVELOPER_ID, the bundle is notarized and stapled
#
# Examples:
#   scripts/package.sh                                  # local, ad-hoc signed
#   ARCHS="arm64" scripts/package.sh                    # fast native build
#   DEVELOPER_ID="Developer ID Application: ... (ABC123)" \
#     NOTARY_PROFILE=pathom-notary scripts/package.sh   # signed + notarized
#
# Store a notarytool profile once with:
#   xcrun notarytool store-credentials pathom-notary \
#     --apple-id you@example.com --team-id ABC123 --password <app-specific-password>

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Pathom"
CONFIG="release"
ARCHS="${ARCHS:-arm64 x86_64}"
BUILD_DIR="$ROOT/.build"
APP="$BUILD_DIR/$APP_NAME.app"

archflags=()
for arch in $ARCHS; do archflags+=(--arch "$arch"); done

echo "==> Building $APP_NAME ($CONFIG; $ARCHS)"
swift build -c "$CONFIG" "${archflags[@]}"
binDir="$(swift build -c "$CONFIG" "${archflags[@]}" --show-bin-path)"
binary="$binDir/$APP_NAME"
[[ -x "$binary" ]] || { echo "error: built binary not found at $binary" >&2; exit 1; }

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$binary" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing"
if [[ -n "${DEVELOPER_ID:-}" ]]; then
	echo "    Developer ID, Hardened Runtime: $DEVELOPER_ID"
	codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
else
	echo "    ad-hoc (set DEVELOPER_ID to sign for distribution)"
	codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

if [[ -n "${NOTARY_PROFILE:-}" && -n "${DEVELOPER_ID:-}" ]]; then
	echo "==> Notarizing"
	zip="$BUILD_DIR/$APP_NAME.zip"
	ditto -c -k --keepParent "$APP" "$zip"
	xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
	xcrun stapler staple "$APP"
	rm -f "$zip"
elif [[ -n "${DEVELOPER_ID:-}" ]]; then
	echo "==> Skipping notarization (set NOTARY_PROFILE to enable)"
fi

if [[ -n "${INSTALL:-}" ]]; then
	dest="/Applications/$APP_NAME.app"
	echo "==> Installing to $dest"
	pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true  # quit a running copy
	sleep 1
	rm -rf "$dest"
	cp -R "$APP" "$dest"
	echo "    installed (open with: open \"$dest\")"
fi

echo "==> Done: $APP"
