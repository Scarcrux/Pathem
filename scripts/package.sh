#!/usr/bin/env bash
#
# Package Pathem into a macOS .app bundle.
#
# Defaults to a universal (arm64 + x86_64), ad-hoc-signed bundle that runs
# locally. To produce a distributable build, set the environment variables below;
# each step is skipped unless its credentials are present, so the script is safe
# to run as-is.
#
#   ARCHS            architectures to build, space separated. Default: the host
#                    arch for local builds (fast, and avoids needing the Metal
#                    toolchain that a universal SwiftTerm build requires);
#                    "arm64 x86_64" when DEVELOPER_ID is set (distribution).
#   DEVELOPER_ID     "Developer ID Application: Name (TEAMID)" to sign for release
#                    with Hardened Runtime (required before notarization)
#   NOTARY_PROFILE   a notarytool keychain profile name; if set together with
#                    DEVELOPER_ID, the bundle is notarized and stapled
#
# Examples:
#   scripts/package.sh                                  # local, ad-hoc signed
#   ARCHS="arm64" scripts/package.sh                    # fast native build
#   DEVELOPER_ID="Developer ID Application: ... (ABC123)" \
#     NOTARY_PROFILE=pathem-notary scripts/package.sh   # signed + notarized
#
# Store a notarytool profile once with:
#   xcrun notarytool store-credentials pathem-notary \
#     --apple-id you@example.com --team-id ABC123 --password <app-specific-password>

set -euo pipefail

# Let SwiftPM use its own (trusted) bare-repo cache under .build even when git's
# safe.bareRepository is 'explicit' (a hardening setting that otherwise breaks
# resolution). Only sets defaults if not already provided.
export GIT_CONFIG_COUNT="${GIT_CONFIG_COUNT:-1}"
export GIT_CONFIG_KEY_0="${GIT_CONFIG_KEY_0:-safe.bareRepository}"
export GIT_CONFIG_VALUE_0="${GIT_CONFIG_VALUE_0:-all}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Pathem"
CONFIG="release"
# Local builds default to the host arch (fast, and a single-arch SwiftTerm build
# only copies its Metal shader instead of compiling it, so no Metal toolchain is
# needed). Distribution builds (DEVELOPER_ID set) go universal.
if [[ -z "${ARCHS:-}" ]]; then
  if [[ -n "${DEVELOPER_ID:-}" ]]; then ARCHS="arm64 x86_64"; else ARCHS="$(uname -m)"; fi
fi
BUILD_DIR="$ROOT/.build"
APP="$BUILD_DIR/$APP_NAME.app"

[[ -n "$ARCHS" ]] || { echo "error: ARCHS is empty" >&2; exit 1; }

# Build each arch separately, then lipo. A single multi-arch `swift build`
# compiles SwiftTerm's Metal shader (needs the Metal toolchain, and is broken
# under some Xcode 26 setups); a single-arch build only COPIES the shader
# (SwiftTerm compiles it at runtime), so this path needs no Metal toolchain.
echo "==> Building $APP_NAME ($CONFIG; $ARCHS)"
binaries=()
archBinDirs=()  # per-arch bin dirs, so out-of-process helpers can be lipo'd across arches
frameworkBinDir=""
# Out-of-process helpers bundled next to the app: the iOS-device (AFC) client and the
# torrent daemon. Both keep risky parsing / network code out of the Full-Disk-Access process.
helperNames=(pathem-afc pathem-torrentd pathem-cli)
for arch in $ARCHS; do
	echo "    building $arch"
	swift build -c "$CONFIG" --arch "$arch"
	archBinDir="$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)"
	[[ -x "$archBinDir/$APP_NAME" ]] || { echo "error: binary not found at $archBinDir/$APP_NAME" >&2; exit 1; }
	binaries+=("$archBinDir/$APP_NAME")
	archBinDirs+=("$archBinDir")
	frameworkBinDir="$archBinDir"  # frameworks (Sparkle) are universal in the xcframework
done

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
if [[ ${#binaries[@]} -gt 1 ]]; then
	lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
else
	cp "${binaries[0]}" "$APP/Contents/MacOS/$APP_NAME"
fi
# Bundle each out-of-process helper next to the app (lipo across arches when universal).
for helper in "${helperNames[@]}"; do
	parts=()
	for dir in "${archBinDirs[@]}"; do
		[[ -x "$dir/$helper" ]] && parts+=("$dir/$helper")
	done
	if [[ ${#parts[@]} -gt 1 ]]; then
		lipo -create "${parts[@]}" -output "$APP/Contents/MacOS/$helper"
	elif [[ ${#parts[@]} -eq 1 ]]; then
		cp "${parts[0]}" "$APP/Contents/MacOS/$helper"
	fi
done
# Embed linked frameworks (Sparkle) and point the binary at them, or the app
# can't launch outside the build tree. Note: we deliberately do not ship
# SwiftTerm's resource bundle (only Shaders.metal for its optional Metal
# renderer; the terminal uses CoreText, and the bundle has no Info.plist so it
# isn't codesignable).
for fw in "$frameworkBinDir"/*.framework; do
	[[ -e "$fw" ]] && cp -R "$fw" "$APP/Contents/Frameworks/"
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
# Ship SwiftPM's resource bundle (localized .strings for the UI). Bundle.module
# finds it in Contents/Resources of the packaged app.
resourceBundle="$frameworkBinDir/${APP_NAME}_${APP_NAME}.bundle"
[[ -d "$resourceBundle" ]] && cp -R "$resourceBundle" "$APP/Contents/Resources/"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
[[ -f "$ROOT/Packaging/$APP_NAME.icns" ]] \
  && cp "$ROOT/Packaging/$APP_NAME.icns" "$APP/Contents/Resources/$APP_NAME.icns"

echo "==> Signing"
# Hardened Runtime on every build so local (ad-hoc / self-signed) builds preserve
# Sparkle's nested HR exactly as the notarized release does.
signargs=(--force --options runtime)
if [[ -n "${DEVELOPER_ID:-}" ]]; then
	echo "    Developer ID, Hardened Runtime: $DEVELOPER_ID"
	signargs+=(--timestamp --sign "$DEVELOPER_ID")
elif [[ -n "${SIGN_IDENTITY:-}" ]]; then
	# A stable local identity (e.g. a self-signed cert from `make dev-cert`), so a
	# Full Disk Access grant survives rebuilds. Not for distribution.
	echo "    local identity (stable across rebuilds): $SIGN_IDENTITY"
	signargs+=(--sign "$SIGN_IDENTITY")
else
	echo "    ad-hoc (set SIGN_IDENTITY for a stable local id, or DEVELOPER_ID to distribute)"
	signargs+=(--sign -)
fi
# Sign inside-out (not --deep, which Apple discourages and which mis-signs nested
# helpers): Sparkle ships nested XPC services, a helper app, and the Autoupdate
# Mach-O. Sign those first, then the framework, then the app.
for fw in "$APP/Contents/Frameworks"/*.framework; do
	[[ -e "$fw" ]] || continue
	# Only the real versioned payload (skips the top-level Current symlinks).
	while IFS= read -r -d '' nested; do
		codesign "${signargs[@]}" "$nested"
	done < <(find "$fw/Versions" \( -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" \) -print0 2>/dev/null)
	codesign "${signargs[@]}" "$fw"
done
# The nested resource bundle is sealed by the app signature, but sign it explicitly
# so `codesign --verify --strict --deep` is satisfied.
resourceBundleInApp="$APP/Contents/Resources/${APP_NAME}_${APP_NAME}.bundle"
[[ -d "$resourceBundleInApp" ]] && codesign "${signargs[@]}" "$resourceBundleInApp"
# Sign the nested helpers before the app (inside-out), like the frameworks.
for helper in "${helperNames[@]}"; do
	[[ -f "$APP/Contents/MacOS/$helper" ]] && codesign "${signargs[@]}" "$APP/Contents/MacOS/$helper"
done
codesign "${signargs[@]}" "$APP"
# --deep here is for VERIFYING (a thorough recursive check, which is correct and not
# deprecated); it is only discouraged for SIGNING, which we do inside-out above.
codesign --verify --strict --deep --verbose=2 "$APP"

if [[ -n "${NOTARY_PROFILE:-}" && -n "${DEVELOPER_ID:-}" ]]; then
	echo "==> Notarizing"
	zip="$BUILD_DIR/$APP_NAME.zip"
	ditto -c -k --keepParent "$APP" "$zip"
	xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
	xcrun stapler staple "$APP"
	rm -f "$zip"
	# Confirm Gatekeeper will actually accept the stapled app (catches a notarization
	# or stapling problem before a user ever sees it).
	spctl --assess --type exec --verbose=4 "$APP"
elif [[ -n "${DEVELOPER_ID:-}" ]]; then
	echo "==> Skipping notarization (set NOTARY_PROFILE to enable)"
fi

if [[ -n "${INSTALL:-}" ]]; then
	dest="/Applications/$APP_NAME.app"
	echo "==> Installing to $dest"
	pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true  # quit a running copy
	# The out-of-process torrent daemon outlives the app by design, so it survives a plain app quit
	# (and its name doesn't match the pattern above) -- kill it too, or a reinstall keeps running the
	# OLD daemon binary. The app respawns a fresh one on next use; downloads resume from checkpoint.
	pkill -f "pathem-torrentd" 2>/dev/null || true
	pkill -f "pathem-afc" 2>/dev/null || true
	sleep 1
	rm -rf "$dest"
	cp -R "$APP" "$dest"
	echo "    installed (open with: open \"$dest\")"
fi

echo "==> Done: $APP"
