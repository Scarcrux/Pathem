#!/usr/bin/env bash
#
# Hermetic controls for the PUBLISH=1 gate in scripts/release.sh. Each case copies the
# real release scripts into a throwaway git repository and runs them under `env -i` with
# a PATH of system tools plus a fake `gh` that only records its arguments, so no case
# can reach GitHub, the Keychain, a build, or the developer's own environment.
# Criteria and controls: docs/PUBLISH_GATE_TESTING.md

set -uo pipefail

SRC="$(cd "$(dirname "$0")/../.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/pathem-publish-gate.XXXXXX")"
trap 'rm -rf "${SCRATCH:?}"' EXIT

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Packaging/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SRC/Packaging/Info.plist")"
GOOD_KEY="$(head -c 32 /dev/urandom | base64)"
GOOD_ID="Developer ID Application: Test Org (ABCDE12345)"
pass=0
fail=0

make_fakebin() {
	local dir="$1" with_gh="$2"
	mkdir -p "$dir"
	[[ "$with_gh" == 1 ]] || return 0
	cat > "$dir/gh" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_GH_LOG"
case "$1 $2" in
	"auth status") [[ "${FAKE_GH_AUTH:-ok}" == ok ]] ;;
	"release view") [[ "${FAKE_GH_EXISTS:-0}" == 1 ]] ;;
	*) exit 0 ;;
esac
EOF
	chmod +x "$dir/gh"
}

# A tagged, clean scratch repository holding the real release scripts.
make_root() {
	local root="$1" key="$2"
	mkdir -p "$root/scripts" "$root/Packaging"
	cp "$SRC/scripts/release.sh" "$SRC/scripts/verify-release.sh" "$SRC/scripts/verify_ed_signature.swift" "$root/scripts/"
	cp "$SRC/Packaging/Info.plist" "$root/Packaging/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $key" "$root/Packaging/Info.plist"
	local g=(git -C "$root" -c user.name=Test -c user.email=test@example.invalid -c core.hooksPath=/dev/null -c commit.gpgsign=false)
	"${g[@]}" init -q
	"${g[@]}" add -A
	"${g[@]}" commit -q -m fixture
	"${g[@]}" tag "v$VERSION"
}

# run_case NAME EXPECT DETAIL [KEY=VALUE ...]
#   EXPECT refuse: non-zero exit, refusal lines exactly DETAIL (space-separated P codes),
#                  never reaches the gate or the build
#   EXPECT gate:   preflight passes and the gate runs, then fails before the build
#   EXPECT dryrun: no preflight, reaches the build
# Every case fails if the fake gh recorded a release create or an upload.
# Mutations: ROOT_KEY=, DIRTY=1, AHEAD=1, NO_GH=1, STUB=1, PREV_BUILD=N (an earlier tag carrying build N); other KEY=VALUE pairs are env.
run_case() {
	local name="$1" expect="$2" detail="$3"
	shift 3
	local dir="$SCRATCH/$name" key="$GOOD_KEY" dirty=0 ahead=0 no_gh=0 stub=0 prev=""
	local envs=(PUBLISH=1 "DEVELOPER_ID=$GOOD_ID" NOTARY_PROFILE=test-profile)
	local kv
	for kv in "$@"; do
		case "$kv" in
			ROOT_KEY=*) key="${kv#ROOT_KEY=}" ;;
			DIRTY=1) dirty=1 ;;
			AHEAD=1) ahead=1 ;;
			NO_GH=1) no_gh=1 ;;
			STUB=1) stub=1 ;;
			PREV_BUILD=*) prev="${kv#PREV_BUILD=}" ;;
			UNSET=*) local drop="${kv#UNSET=}" kept=() e
				for e in "${envs[@]}"; do [[ "$e" == "$drop="* ]] || kept+=("$e"); done
				envs=(${kept[@]+"${kept[@]}"}) ;;
			*) envs+=("$kv") ;;
		esac
	done
	make_root "$dir/root" "$key"
	if [[ $stub == 1 ]]; then
		printf '#!/bin/bash\ngh release create v0 bogus.dmg\nexit 1\n' > "$dir/root/scripts/release.sh"
	fi
	if [[ -n "$prev" ]]; then
		local pg=(git -C "$dir/root" -c user.name=Test -c user.email=test@example.invalid -c core.hooksPath=/dev/null -c commit.gpgsign=false)
		/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $prev" "$dir/root/Packaging/Info.plist"
		"${pg[@]}" commit -q -a --allow-empty -m "earlier release"
		"${pg[@]}" tag v0.0.1
		"${pg[@]}" checkout -q --detach "v$VERSION"
	fi
	[[ $dirty == 1 ]] && touch "$dir/root/untracked.txt"
	[[ $ahead == 1 ]] && git -C "$dir/root" -c user.name=Test -c user.email=test@example.invalid \
		-c core.hooksPath=/dev/null commit -q --allow-empty -m ahead
	make_fakebin "$dir/bin" "$((1 - no_gh))"
	local log="$dir/gh.log" out="$dir/out.txt" status
	: > "$log"
	env -i HOME="$HOME" TMPDIR="$SCRATCH" PATH="$dir/bin:/usr/bin:/bin:/usr/sbin" \
		FAKE_GH_LOG="$log" ${envs[@]+"${envs[@]}"} /bin/bash "$dir/root/scripts/release.sh" > "$out" 2>&1
	status=$?

	local problems=() codes
	grep -Eq 'release (create|upload)|^upload' "$log" && problems+=("gh write recorded: $(grep -E 'create|upload' "$log" | head -1)")
	codes="$(sed -n 's/^  - \(P[0-9]\).*/\1/p' "$out" | tr '\n' ' ' | sed 's/ $//')"
	case "$expect" in
		refuse)
			[[ $status != 0 ]] || problems+=("exit 0")
			[[ "$codes" == "$detail" ]] || problems+=("refusal codes '${codes}' want '$detail'")
			grep -q '==> Running the release gate' "$out" && problems+=("reached the gate")
			grep -q '==> Building the app bundle' "$out" && problems+=("reached the build")
			;;
		gate)
			[[ $status != 0 ]] || problems+=("exit 0 without a gate")
			grep -q 'publish preflight passed' "$out" || problems+=("preflight did not pass: $(grep -m1 -- '  - P' "$out")")
			grep -q '==> Running the release gate' "$out" || problems+=("gate never ran")
			grep -q '==> Building the app bundle' "$out" && problems+=("built after a failed gate")
			;;
		dryrun)
			grep -q '==> Checking publish requirements' "$out" && problems+=("dry run ran the publish preflight")
			grep -q '==> Building the app bundle' "$out" || problems+=("dry run never reached the build")
			[[ -s "$log" ]] && problems+=("dry run called gh: $(head -1 "$log")")
			;;
	esac
	if [[ ${#problems[@]} -eq 0 ]]; then
		printf 'PASS %-28s %s\n' "$name" "${codes:-$expect}"
		return 0
	fi
	printf 'FAIL %-28s %s\n' "$name" "$(IFS='; '; echo "${problems[*]}")"
	return 1
}

check() { if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi; }

check run_case nothing-set          refuse "P1 P2" UNSET=DEVELOPER_ID UNSET=NOTARY_PROFILE
check run_case p1-missing           refuse "P1"    UNSET=DEVELOPER_ID
check run_case p1-wrong-cert-kind   refuse "P1"    "DEVELOPER_ID=Apple Development: Test Org (ABCDE12345)"
check run_case p1-no-team           refuse "P1"    "DEVELOPER_ID=Developer ID Application: Test Org"
check run_case p2-no-notary         refuse "P2"    UNSET=NOTARY_PROFILE
check run_case p3-placeholder-key   refuse "P3"    ROOT_KEY=REPLACE_WITH_SPARKLE_PUBLIC_KEY
check run_case p3-short-key         refuse "P3"    ROOT_KEY=YWJj
check run_case p4-unreadable-key    refuse "P4"    SPARKLE_KEY_FILE=/nonexistent/sparkle.key
check run_case p5-gh-missing        refuse "P5"    NO_GH=1
check run_case p5-gh-unauth         refuse "P5"    FAKE_GH_AUTH=fail
check run_case p6-untracked-file    refuse "P6"    DIRTY=1
check run_case p6-head-past-tag     refuse "P6"    AHEAD=1
check run_case p7-already-released  refuse "P7"    FAKE_GH_EXISTS=1
check run_case p8-build-equal       refuse "P8"    "PREV_BUILD=$BUILD"
check run_case p8-build-lower       refuse "P8"    "PREV_BUILD=$((BUILD + 5))"
check run_case p8-build-higher-ok   gate   ""      "PREV_BUILD=$((BUILD - 1))"
check run_case satisfied            gate   ""
check run_case satisfied-key-file   gate   ""      "SPARKLE_KEY_FILE=$SRC/Packaging/Info.plist"
check run_case dry-run-no-creds     dryrun ""      UNSET=PUBLISH UNSET=DEVELOPER_ID UNSET=NOTARY_PROFILE

# Synthetic cheater: a release script that skips preflight and calls gh release create.
# The harness must report it as FAIL; the control passes only if it does.
echo "--- control: synthetic cheater must be reported FAIL ---"
if run_case cheater refuse "P1" STUB=1; then
	echo "FAIL control: the harness accepted a script that publishes without preflight"
	fail=$((fail + 1))
else
	echo "PASS control: the harness rejected the cheater"
	pass=$((pass + 1))
fi

total=$((pass + fail))
if [[ $fail -eq 0 ]]; then
	echo "RESULT: PASS ($pass/$total)"
else
	echo "RESULT: FAIL ($fail of $total)"
	exit 1
fi
