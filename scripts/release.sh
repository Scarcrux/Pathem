#!/usr/bin/env bash
#
# Cut a distributable Pathem release: build + sign (+ notarize) the .app, wrap it
# in a DMG, sign the DMG for Sparkle, regenerate the appcast, and (optionally)
# publish the GitHub release.
#
# Version and build number are read from Packaging/Info.plist
# (CFBundleShortVersionString / CFBundleVersion) — bump them there and commit
# before releasing.
#
# Credentials are all optional and each gates its own step, so a credential-free
# run still produces a DMG + appcast for inspection (just unsigned/un-notarized,
# which real clients would reject — the script says so loudly):
#
#   DEVELOPER_ID     "Developer ID Application: Name (TEAMID)" — Hardened-Runtime
#                    signing for distribution (passed through to package.sh)
#   NOTARY_PROFILE   notarytool keychain profile — notarize + staple the .app
#   PUBLISH=1        create the GitHub release and upload the DMG + appcast (needs
#                    `gh` authenticated). Without it, artifacts stay in dist/.
#   REPO             GitHub owner/name for enclosure URLs. Default: Scarcrux/Pathem
#
# One-time prerequisite: scripts/setup-sparkle-key.sh (the EdDSA update key).
#
# Examples:
#   scripts/release.sh                                   # local dry run into dist/
#   DEVELOPER_ID="Developer ID Application: … (ABC123)" \
#     NOTARY_PROFILE=pathem-notary PUBLISH=1 scripts/release.sh

set -euo pipefail

export GIT_CONFIG_COUNT="${GIT_CONFIG_COUNT:-1}"
export GIT_CONFIG_KEY_0="${GIT_CONFIG_KEY_0:-safe.bareRepository}"
export GIT_CONFIG_VALUE_0="${GIT_CONFIG_VALUE_0:-all}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Pathem"
PLIST="$ROOT/Packaging/Info.plist"
APP="$ROOT/.build/$APP_NAME.app"
DIST="$ROOT/dist"
REPO="${REPO:-Scarcrux/Pathem}"

pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
VERSION="$(pb CFBundleShortVersionString)"
BUILD="$(pb CFBundleVersion)"
MIN_OS="$(pb LSMinimumSystemVersion)"
[[ -n "$VERSION" && -n "$BUILD" ]] || { echo "error: version/build missing from Info.plist" >&2; exit 1; }
TAG="v$VERSION"
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG="$DIST/$DMG_NAME"

echo "==> Releasing $APP_NAME $VERSION (build $BUILD) as $TAG"

# Refuse to overwrite a version that's already published upstream (a common footgun).
if [[ "${PUBLISH:-}" == "1" ]] && command -v gh >/dev/null 2>&1; then
	if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
		echo "error: release $TAG already exists on $REPO. Bump the version in Info.plist." >&2
		exit 1
	fi
fi

# 1) Build, sign, and (if creds present) notarize the .app.
echo "==> Building the app bundle"
"$ROOT/scripts/package.sh"
[[ -d "$APP" ]] || { echo "error: $APP not produced by package.sh" >&2; exit 1; }

# 2) Wrap it in a compressed DMG with a drag-to-Applications target.
echo "==> Building $DMG_NAME"
mkdir -p "$DIST"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "    $(du -h "$DMG" | cut -f1)  $DMG"

# 3) Sign the DMG with the Sparkle EdDSA key (from the login Keychain). Without a
#    key the appcast is emitted unsigned and clients will reject the update, so we
#    warn hard rather than silently ship something that can't install.
SPARKLE_BIN="$(find "$ROOT/.build/artifacts" -type d -name bin -path '*sparkle*' 2>/dev/null | head -n1)"
SIG_ATTRS=""
if [[ -n "$SPARKLE_BIN" && -x "$SPARKLE_BIN/sign_update" ]]; then
	echo "==> Signing the DMG for Sparkle"
	if SIG_ATTRS="$("$SPARKLE_BIN/sign_update" "$DMG" 2>/dev/null)"; then
		echo "    $SIG_ATTRS"
	else
		SIG_ATTRS=""
	fi
fi
if [[ -z "$SIG_ATTRS" ]]; then
	echo "    WARNING: no Sparkle signature (run scripts/setup-sparkle-key.sh first)." >&2
	# Fall back to length only so the appcast is still well-formed for inspection.
	LEN="$(stat -f%z "$DMG")"
	SIG_ATTRS="length=\"$LEN\" type=\"application/octet-stream\""
else
	SIG_ATTRS="$SIG_ATTRS type=\"application/octet-stream\""
fi

# 4) Regenerate the appcast. Each release drops one item fragment under
#    dist/appcast.d/, and we rebuild appcast.xml from all fragments (newest build
#    first). Older versions keep their own per-tag download URLs, which stay valid
#    on GitHub forever, so users far behind still get a correct upgrade path.
echo "==> Updating appcast.xml"
FRAG_DIR="$DIST/appcast.d"
mkdir -p "$FRAG_DIR"
DL_URL="https://github.com/$REPO/releases/download/$TAG/$DMG_NAME"
PUB_DATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"
cat > "$FRAG_DIR/$(printf '%08d' "$BUILD").xml" <<EOF
    <item>
      <title>Version $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <link>https://github.com/$REPO</link>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:releaseNotesLink>
      <enclosure url="$DL_URL" $SIG_ATTRS />
    </item>
EOF

APPCAST="$DIST/appcast.xml"
{
	echo '<?xml version="1.0" encoding="utf-8"?>'
	echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">'
	echo '  <channel>'
	echo "    <title>$APP_NAME</title>"
	echo "    <link>https://github.com/$REPO</link>"
	echo "    <description>Updates for $APP_NAME.</description>"
	echo '    <language>en</language>'
	# Newest build number first.
	for frag in $(ls -1 "$FRAG_DIR"/*.xml 2>/dev/null | sort -r); do cat "$frag"; done
	echo '  </channel>'
	echo '</rss>'
} > "$APPCAST"
echo "    $APPCAST"

# 5) Optionally publish to GitHub Releases (the feed URL resolves to the latest
#    release's appcast.xml, so uploading it here is what actually ships the update).
if [[ "${PUBLISH:-}" == "1" ]]; then
	command -v gh >/dev/null 2>&1 || { echo "error: PUBLISH=1 but gh is not installed" >&2; exit 1; }
	echo "==> Publishing $TAG to $REPO"
	gh release create "$TAG" "$DMG" "$APPCAST" \
		--repo "$REPO" --title "$APP_NAME $VERSION" --generate-notes
	echo "    published: https://github.com/$REPO/releases/tag/$TAG"
else
	echo "==> Not publishing (set PUBLISH=1 to create the GitHub release)."
	echo "    Artifacts ready in dist/: $DMG_NAME, appcast.xml"
fi

echo "==> Done."
