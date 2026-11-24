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
# Without PUBLISH=1, credentials are optional and each gates its own step, so a
# credential-free dry run still produces a DMG + appcast in dist/ for inspection
# (unsigned/un-notarized, which real clients would reject; the script says so).
#
# PUBLISH=1 fails closed. Before anything is built it requires every credential,
# a real Sparkle public key, an authenticated gh, a clean tree whose HEAD is the
# version tag, an unpublished tag, and a build number above every earlier v* tag's; then `make ci` must pass; then the built app
# and DMG must pass scripts/verify-release.sh before anything is uploaded.
# Criteria: docs/PUBLISH_GATE_TESTING.md.
#
#   DEVELOPER_ID     "Developer ID Application: Name (TEAMID)" for Hardened-Runtime
#                    signing (passed through to package.sh)
#   NOTARY_PROFILE   notarytool keychain profile to notarize + staple the .app
#   SPARKLE_KEY_FILE optional EdDSA private key file for sign_update; without it the
#                    key is read from the login Keychain
#   PUBLISH=1        create the GitHub release and upload the DMG + appcast
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

PUBLISHING=0
[[ "${PUBLISH:-}" == "1" ]] && PUBLISHING=1

if [[ $PUBLISHING == 1 && "${PATHEM_THEMES_BETA:-}" == "1" ]]; then
	echo "error: Themes beta packages cannot be published through the stable release path." >&2
	exit 1
fi
TEAM_ID=""
HEAD_SHA=""

# Highest CFBundleVersion recorded in Packaging/Info.plist at any existing v* tag other
# than this release's own tag. Local git only, no network. Prints "BUILD TAG" or nothing.
previous_build() {
	local t b best="" best_tag="" tmp
	tmp="$(mktemp "${TMPDIR:-/tmp}/pathem-prevplist.XXXXXX")"
	while IFS= read -r t; do
		[[ -n "$t" && "$t" != "$TAG" ]] || continue
		git -C "$ROOT" show "$t:Packaging/Info.plist" > "$tmp" 2>/dev/null || continue
		b="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$tmp" 2>/dev/null || true)"
		[[ "$b" =~ ^[0-9]+$ ]] || continue
		if [[ -z "$best" || "$b" -gt "$best" ]]; then best="$b"; best_tag="$t"; fi
	done < <(git -C "$ROOT" tag --list 'v*' 2>/dev/null)
	rm -f "$tmp"
	[[ -z "$best" ]] || echo "$best $best_tag"
}

# Every publish requirement is checked before anything is built, gated or uploaded,
# and all failures are reported together.
preflight_publish() {
	local problems=()
	local id_re='^Developer ID Application: .+ \(([A-Z0-9]{10})\)$'
	if [[ "${DEVELOPER_ID:-}" =~ $id_re ]]; then
		TEAM_ID="${BASH_REMATCH[1]}"
	else
		problems+=("P1 DEVELOPER_ID must be 'Developer ID Application: <name> (<TEAMID>)' (got '${DEVELOPER_ID:-unset}')")
	fi
	[[ -n "${NOTARY_PROFILE:-}" ]] || problems+=("P2 NOTARY_PROFILE is unset; publishing requires notarization and stapling")
	local key keylen
	key="$(pb SUPublicEDKey 2>/dev/null || true)"
	keylen="$(printf '%s' "$key" | base64 -D 2>/dev/null | wc -c | tr -d ' ')"
	if [[ "$key" == "REPLACE_WITH_SPARKLE_PUBLIC_KEY" || "$keylen" != "32" ]]; then
		problems+=("P3 SUPublicEDKey in Packaging/Info.plist is not a real Ed25519 public key (run scripts/setup-sparkle-key.sh)")
	fi
	if [[ -n "${SPARKLE_KEY_FILE:-}" && ! -r "$SPARKLE_KEY_FILE" ]]; then
		problems+=("P4 SPARKLE_KEY_FILE is set but is not a readable file: $SPARKLE_KEY_FILE")
	fi
	local gh_ready=0
	if ! command -v gh >/dev/null 2>&1; then
		problems+=("P5 gh is not installed")
	elif ! gh auth status >/dev/null 2>&1; then
		problems+=("P5 gh is not authenticated (gh auth login)")
	else
		gh_ready=1
	fi
	if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then
		problems+=("P6 the working tree has uncommitted or untracked changes")
	fi
	local tagged
	HEAD_SHA="$(git -C "$ROOT" rev-parse -q --verify HEAD 2>/dev/null || true)"
	tagged="$(git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG^{commit}" 2>/dev/null || true)"
	if [[ -z "$tagged" || "$HEAD_SHA" != "$tagged" ]]; then
		problems+=("P6 HEAD is not the release tag $TAG (commit and tag the version first)")
	fi
	if [[ $gh_ready == 1 ]] && gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
		problems+=("P7 release $TAG already exists on $REPO; bump the version in Info.plist")
	fi
	local prev prev_build prev_tag
	prev="$(previous_build)"
	if [[ -n "$prev" ]]; then
		prev_build="${prev%% *}"
		prev_tag="${prev#* }"
		if [[ "$BUILD" =~ ^[0-9]+$ ]] && (( BUILD > prev_build )); then :; else
			problems+=("P8 CFBundleVersion $BUILD must be strictly greater than $prev_build, the highest build at an earlier release tag ($prev_tag); bump it in Packaging/Info.plist")
		fi
	fi
	if [[ ${#problems[@]} -gt 0 ]]; then
		echo "error: refusing to publish:" >&2
		local p
		for p in "${problems[@]}"; do echo "  - $p" >&2; done
		exit 1
	fi
	echo "    publish preflight passed (team $TEAM_ID, $TAG at ${HEAD_SHA:0:12})"
}

if [[ $PUBLISHING != 1 ]]; then
	prev="$(previous_build)"
	if [[ -n "$prev" ]] && ! { [[ "$BUILD" =~ ^[0-9]+$ ]] && (( BUILD > ${prev%% *} )); }; then
		echo "warning: CFBundleVersion $BUILD is not greater than ${prev%% *} (at ${prev#* }); PUBLISH=1 would refuse (P8)" >&2
	fi
fi

if [[ $PUBLISHING == 1 ]]; then
	echo "==> Checking publish requirements"
	preflight_publish
	echo "==> Running the release gate (make ci)"
	make -C "$ROOT" ci
fi

# 1) Build, sign, and (if creds present) notarize the .app.
echo "==> Building the app bundle"
"$ROOT/scripts/package.sh"
[[ -d "$APP" ]] || { echo "error: $APP not produced by package.sh" >&2; exit 1; }
if [[ $PUBLISHING == 1 ]]; then
	echo "==> Verifying the app for distribution"
	"$ROOT/scripts/verify-release.sh" app "$APP" "$TEAM_ID"
fi

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

# 2b) Sign, notarize and staple the DMG itself, so the download is accepted on its own and
#     not only the app inside it. This must happen before the Sparkle signature below:
#     stapling changes the file's bytes.
if [[ -n "${DEVELOPER_ID:-}" ]]; then
	echo "==> Signing the DMG"
	codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
	if [[ -n "${NOTARY_PROFILE:-}" ]]; then
		echo "==> Notarizing the DMG"
		xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
		xcrun stapler staple "$DMG"
	fi
fi
if [[ $PUBLISHING == 1 ]]; then
	"$ROOT/scripts/verify-release.sh" dmg "$DMG" "$TEAM_ID"
fi

# 3) Sign the DMG with the Sparkle EdDSA key (SPARKLE_KEY_FILE, else the login
#    Keychain). A dry run without a key emits an unsigned appcast for inspection and
#    warns; a publish refuses, and the signature must verify against the public key
#    embedded in the app being shipped, or installed copies could never update.
SPARKLE_BIN="$(find "$ROOT/.build/artifacts" -type d -name bin -path '*sparkle*' 2>/dev/null | head -n1)"
SIGN_ARGS=()
[[ -n "${SPARKLE_KEY_FILE:-}" ]] && SIGN_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
SIG_ATTRS=""
if [[ -n "$SPARKLE_BIN" && -x "$SPARKLE_BIN/sign_update" ]]; then
	echo "==> Signing the DMG for Sparkle"
	if SIG_ATTRS="$("$SPARKLE_BIN/sign_update" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$DMG" 2>/dev/null)"; then
		echo "    $SIG_ATTRS"
	else
		SIG_ATTRS=""
	fi
fi
ED_SIG="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIG_ATTRS")"
if [[ $PUBLISHING == 1 ]]; then
	if [[ -z "$ED_SIG" ]]; then
		echo "error: refusing to publish: the DMG has no Sparkle EdDSA signature (no key in SPARKLE_KEY_FILE or the Keychain)." >&2
		exit 1
	fi
	"$ROOT/scripts/verify-release.sh" signature "$APP" "$DMG" "$ED_SIG"
fi
if [[ -z "$ED_SIG" ]]; then
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

# The published appcast must carry the verified signature and the DMG's exact length
# for this release, and no item may be unsigned (a leftover dry-run fragment would be).
if [[ $PUBLISHING == 1 ]]; then
	"$ROOT/scripts/verify-release.sh" appcast "$APPCAST" "$DL_URL" "$DMG" "$ED_SIG"
fi

# 5) Optionally publish to GitHub Releases (the feed URL resolves to the latest
#    release's appcast.xml, so uploading it here is what actually ships the update).
#    --target pins a newly created tag to the verified commit, never the default branch.
if [[ $PUBLISHING == 1 ]]; then
	echo "==> Publishing $TAG to $REPO"
	# The release body is this version's entry from the in-app changelog (the curated
	# notes users also see under Help > Release Notes), not GitHub's commit list.
	NOTES="$(mktemp)"
	awk -v v="## $VERSION " 'index($0, v) == 1 {on = 1; next} on && /^## / {exit} on' \
		"$ROOT/Sources/Pathem/Resources/CHANGELOG.md" > "$NOTES"
	[[ -s "$NOTES" ]] || { echo "error: no CHANGELOG entry for $VERSION" >&2; exit 1; }
	gh release create "$TAG" "$DMG" "$APPCAST" \
		--repo "$REPO" --target "$HEAD_SHA" --title "$APP_NAME $VERSION" --notes-file "$NOTES"
	echo "    published: https://github.com/$REPO/releases/tag/$TAG"
else
	echo "==> Not publishing (set PUBLISH=1 to create the GitHub release)."
	echo "    Artifacts ready in dist/: $DMG_NAME, appcast.xml"
fi

echo "==> Done."
