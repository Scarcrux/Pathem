#!/usr/bin/env bash
#
# Verify a distribution artifact before it is published. Read-only: it never signs,
# notarizes, uploads or touches the Keychain. Every check runs and reports its own
# PASS/FAIL line; the exit status is 0 only when all of them pass.
#
#   scripts/verify-release.sh app <Pathem.app> <TEAMID>
#       A1 strict signature, A2 Developer ID leaf + team, A3 hardened runtime,
#       A4 stapled ticket, A5 Gatekeeper, A6 universal executables,
#       A10 the Photos entitlement is signed in, A11 third-party notices are bundled
#   scripts/verify-release.sh signature <Pathem.app> <update.dmg> <base64 edSignature>
#       A7 the DMG's EdDSA signature verifies against the app's own SUPublicEDKey
#   scripts/verify-release.sh dmg <update.dmg> <TEAMID>
#       A9 the DMG itself is Developer ID signed by the team, stapled, and accepted by Gatekeeper
#   scripts/verify-release.sh appcast <appcast.xml> <download url> <update.dmg> <base64 edSignature>
#       A8 the item for that URL carries the signature and the DMG's byte length, and
#          every item in the feed is signed
#
# Criteria and controls: docs/PUBLISH_GATE_TESTING.md

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; failures=$((failures + 1)); }

usage() {
	sed -n '6,16p' "$0" >&2
	exit 2
}

verify_app() {
	local app="$1" team="$2"
	[[ -d "$app/Contents" ]] || { echo "FAIL not an app bundle: $app"; exit 1; }
	local exe
	exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null)"
	local main="$app/Contents/MacOS/$exe"

	if codesign --verify --strict --deep "$app" 2>/dev/null; then
		pass "A1 strict deep signature verifies"
	else
		fail "A1 strict deep signature does not verify"
	fi

	local details leaf actual_team
	details="$(codesign -dvv "$app" 2>&1)"
	leaf="$(sed -n 's/^Authority=//p' <<<"$details" | head -1)"
	actual_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$details" | head -1)"
	if [[ "$leaf" == "Developer ID Application: "* && "$actual_team" == "$team" ]]; then
		pass "A2 Developer ID leaf, team $actual_team"
	else
		fail "A2 leaf '${leaf:-none (ad-hoc)}' team '${actual_team:-none}' (want Developer ID Application, team $team)"
	fi

	# Capture first: with pipefail, grep -q closing the pipe early would SIGPIPE codesign.
	local cd_line
	cd_line="$(codesign -dv "$main" 2>&1 | grep '^CodeDirectory ')"
	if [[ "$cd_line" =~ flags=0x[0-9a-f]+\([^\)]*runtime ]]; then
		pass "A3 hardened runtime on $exe"
	else
		fail "A3 hardened runtime flag missing on $exe"
	fi

	if xcrun stapler validate "$app" >/dev/null 2>&1; then
		pass "A4 notarization ticket stapled"
	else
		fail "A4 no stapled notarization ticket"
	fi

	if /usr/sbin/spctl --assess --type execute "$app" 2>/dev/null; then
		pass "A5 Gatekeeper accepts the app"
	else
		fail "A5 Gatekeeper rejects the app"
	fi

	local found=0 bad=""
	while IFS= read -r -d '' f; do
		[[ "$(file -b "$f")" == *Mach-O* ]] || continue
		found=$((found + 1))
		local archs
		archs=" $(lipo -archs "$f" 2>/dev/null) "
		[[ "$archs" == *" arm64 "* && "$archs" == *" x86_64 "* ]] || bad+=" $(basename "$f")($(echo $archs))"
	done < <(find "$app/Contents/MacOS" -type f -perm +111 -print0)
	if [[ $found -gt 0 && -z "$bad" ]]; then
		pass "A6 all $found executables are arm64+x86_64"
	else
		fail "A6 not universal:${bad:- no executables found}"
	fi
	# Without this entitlement the hardened runtime denies PhotoKit with no prompt.
	if codesign -d --entitlements - --xml "$app" 2>/dev/null \
		| grep -q "com.apple.security.personal-information.photos-library"; then
		pass "A10 Photos entitlement is signed in"
	else
		fail "A10 Photos entitlement missing (the Photos browser would be denied)"
	fi
	local notices="$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
	if [[ -f "$notices" ]] && grep -q "SwiftTerm" "$notices" && grep -q "Sparkle" "$notices" \
		&& [[ -f "$app/Contents/Resources/Credits.html" ]]; then
		pass "A11 third-party notices bundled (SwiftTerm, Sparkle, About credits)"
	else
		fail "A11 third-party notices missing from the app"
	fi
}

verify_signature() {
	local app="$1" dmg="$2" sig="$3"
	local key
	key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist" 2>/dev/null)"
	if [[ -z "$key" || "$key" == "REPLACE_WITH_SPARKLE_PUBLIC_KEY" ]]; then
		fail "A7 the app has no real SUPublicEDKey ('${key:-missing}')"
		return
	fi
	local tmp
	tmp="$(mktemp -d)"
	if ! xcrun swiftc -O "$ROOT/scripts/verify_ed_signature.swift" -o "$tmp/verify" >/dev/null 2>&1; then
		rm -rf "$tmp"
		fail "A7 could not build the signature verifier"
		return
	fi
	local verdict
	verdict="$("$tmp/verify" "$key" "$sig" "$dmg")"
	rm -rf "$tmp"
	if [[ "$verdict" == "ACCEPT" ]]; then
		pass "A7 DMG EdDSA signature verifies against the app's SUPublicEDKey"
	else
		fail "A7 $verdict"
	fi
}

verify_dmg() {
	local dmg="$1" team="$2"
	[[ -r "$dmg" ]] || { fail "A9 unreadable DMG: $dmg"; return; }
	local details leaf actual_team
	details="$(codesign -dvv "$dmg" 2>&1)"
	leaf="$(sed -n 's/^Authority=//p' <<<"$details" | head -1)"
	actual_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$details" | head -1)"
	if codesign --verify --strict "$dmg" 2>/dev/null \
		&& [[ "$leaf" == "Developer ID Application: "* && "$actual_team" == "$team" ]]; then
		pass "A9 DMG signed with Developer ID, team $actual_team"
	else
		fail "A9 DMG leaf '${leaf:-none (unsigned)}' team '${actual_team:-none}' (want Developer ID Application, team $team)"
	fi
	if xcrun stapler validate "$dmg" >/dev/null 2>&1; then
		pass "A9 DMG notarization ticket stapled"
	else
		fail "A9 DMG has no stapled notarization ticket"
	fi
	if /usr/sbin/spctl --assess --type open --context context:primary-signature "$dmg" 2>/dev/null; then
		pass "A9 Gatekeeper accepts the DMG"
	else
		fail "A9 Gatekeeper rejects the DMG"
	fi
}

verify_appcast() {
	local appcast="$1" url="$2" dmg="$3" sig="$4"
	[[ -r "$appcast" && -r "$dmg" ]] || { fail "A8 unreadable appcast or DMG"; return; }
	local len item enclosures signed
	len="$(stat -f%z "$dmg")"
	item="$(grep -F "url=\"$url\"" "$appcast" || true)"
	if [[ -n "$item" && "$item" == *"sparkle:edSignature=\"$sig\""* && "$item" == *"length=\"$len\""* ]]; then
		pass "A8 item for this release carries the signature and length $len"
	else
		fail "A8 no item for $url with the verified signature and length $len"
	fi
	enclosures="$(grep -c '<enclosure ' "$appcast" || true)"
	signed="$(grep -c '<enclosure .*sparkle:edSignature="' "$appcast" || true)"
	if [[ "$enclosures" -gt 0 && "$enclosures" == "$signed" ]]; then
		pass "A8 all $enclosures appcast item(s) are signed"
	else
		fail "A8 $((enclosures - signed)) of $enclosures appcast item(s) have no EdDSA signature"
	fi
}

case "${1:-}" in
	app) [[ $# -eq 3 ]] || usage; verify_app "$2" "$3" ;;
	signature) [[ $# -eq 4 ]] || usage; verify_signature "$2" "$3" "$4" ;;
	dmg) [[ $# -eq 3 ]] || usage; verify_dmg "$2" "$3" ;;
	appcast) [[ $# -eq 5 ]] || usage; verify_appcast "$2" "$3" "$4" "$5" ;;
	*) usage ;;
esac

if [[ $failures -eq 0 ]]; then
	echo "RESULT: PASS"
else
	echo "RESULT: FAIL ($failures)"
	exit 1
fi
