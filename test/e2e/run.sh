#!/usr/bin/env bash
#
# Blackbox end-to-end harness for Pathem.
#
# Launches the REAL built product and asserts behavior from the outside (no access to
# internals): the app launches without crashing, exercises deterministic local features,
# crosses daemon and remote-provider process boundaries, virtualizes a 1M-row directory,
# resolves bundled localization, and lays out key panels. Each scenario is driven by a
# PATHEM_* environment switch and prints a "RESULT: PASS/SKIP/FAIL" line we grep for.
#
# Usage:
#   test/e2e/run.sh              # fast: against the debug `swift build` binary
#   test/e2e/run.sh --packaged   # against the signed .app from package.sh (also checks
#                                # the bundle is complete: catches packaging regressions
#                                # like the missing-resource-bundle launch crash)
#
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
"$ROOT/scripts/toolchain_preflight.sh" || exit 1

# Every debug scenario gets disposable application state. This keeps daemon/config checks from
# reading or mutating the user's real Application Support data.
E2E_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/pathem-e2e.XXXXXX")"
WEBDAV_PID=""
OBJECT_STORAGE_PID=""
cleanup() {
  if [[ -n "$WEBDAV_PID" ]]; then
    kill -TERM "$WEBDAV_PID" 2>/dev/null || true
    wait "$WEBDAV_PID" 2>/dev/null || true
  fi
  if [[ -n "$OBJECT_STORAGE_PID" ]]; then
    kill -TERM "$OBJECT_STORAGE_PID" 2>/dev/null || true
    wait "$OBJECT_STORAGE_PID" 2>/dev/null || true
  fi
  rm -rf "$E2E_SCRATCH"
}
trap cleanup EXIT
export PATHEM_CONFIG_DIR="$E2E_SCRATCH/config"
export PATHEM_CAPTURE_DIR="$E2E_SCRATCH/captures"
mkdir -p "$PATHEM_CAPTURE_DIR"

# Let SwiftPM use its own trusted bare-repo cache even under git safe.bareRepository.
export GIT_CONFIG_COUNT="${GIT_CONFIG_COUNT:-1}"
export GIT_CONFIG_KEY_0="${GIT_CONFIG_KEY_0:-safe.bareRepository}"
export GIT_CONFIG_VALUE_0="${GIT_CONFIG_VALUE_0:-all}"

PACKAGED=0
[[ "${1:-}" == "--packaged" ]] && PACKAGED=1

green=$'\033[32m'; red=$'\033[31m'; yellow=$'\033[33m'; dim=$'\033[2m'; rst=$'\033[0m'
pass=0; fail=0; skip=0

# Run a command with a wall-clock timeout (macOS has no `timeout`); no sleep involved.
timeout_run() { perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$@"; }

scenario_succeeded() {
  local command_status="$1" out="$2" expect="$3"
  local result; result="$(grep -oE '^RESULT:.*' <<<"$out" | tail -1)"
  [[ "$command_status" == 0 ]] \
    && grep -qE '^RESULT: (PASS|SKIP)([[:space:]:]|$)' <<<"$result" \
    && grep -qE "$expect" <<<"$result"
}

capture_disposition() {
  local status="$1" out="$2" allow_transparency="${3:-0}"
  if scenario_succeeded "$status" "$out" 'RESULT: PASS'; then printf 'PASS'
  elif [[ "$allow_transparency" == 1 && "$status" == 1 ]] \
    && grep -q '\[mostly-transparent\]' <<<"$out"; then printf 'SKIP'
  else printf 'FAIL'; fi
}

scenario_self_test() {
  local total=0 passed=0
  completion_control() {
    local name="$1" command_status="$2" out="$3" expect="$4" should_pass="$5" actual=0
    scenario_succeeded "$command_status" "$out" "$expect" && actual=1
    total=$((total+1))
    if [[ "$actual" == "$should_pass" ]]; then
      passed=$((passed+1)); printf 'SCENARIOCONTROL: PASS %s exit=%s accepted=%s\n' "$name" "$command_status" "$actual"
    else
      printf 'SCENARIOCONTROL: FAIL %s exit=%s accepted=%s expected=%s\n' "$name" "$command_status" "$actual" "$should_pass"
    fi
  }
  completion_control good 0 'RESULT: PASS' 'RESULT: PASS' 1
  completion_control legacy-colon-success 0 'RESULT: PASS: table materializes bounded cells' 'RESULT: PASS' 1
  completion_control allowed-skip 0 'RESULT: SKIP fixture unavailable' 'RESULT: (PASS|SKIP)' 1
  local out command_status
  out="$(sh -c 'printf "RESULT: PASS\n"; exit 7')"; command_status=$?
  completion_control pass-then-error "$command_status" "$out" 'RESULT: PASS' 0
  completion_control final-fail 0 $'RESULT: PASS\nRESULT: FAIL' 'RESULT: PASS' 0
  completion_control missing-result 0 'no structured result' 'RESULT: PASS' 0
  completion_control malformed-result 0 'RESULT: PASSIVE' 'RESULT: PASS' 0
  completion_control embedded-pass-in-failure 0 'RESULT: FAIL detail RESULT: PASS' 'RESULT: PASS' 0
  completion_control unallowed-skip 0 'RESULT: SKIP' 'RESULT: PASS' 0
  out="$(timeout_run 1 sh -c 'printf "RESULT: PASS\n"; exec sleep 3' 2>&1)"; command_status=$?
  completion_control pass-then-timeout "$command_status" "$out" 'RESULT: PASS' 0
  capture_control() {
    local name="$1" status="$2" out="$3" allowed="$4" expected="$5" actual
    actual="$(capture_disposition "$status" "$out" "$allowed")"
    total=$((total+1))
    if [[ "$actual" == "$expected" ]]; then
      passed=$((passed+1)); printf 'CAPTUREPOLICY: PASS %s actual=%s\n' "$name" "$actual"
    else printf 'CAPTUREPOLICY: FAIL %s actual=%s expected=%s\n' "$name" "$actual" "$expected"; fi
  }
  capture_control good 0 'RESULT: PASS' 0 PASS
  capture_control strict-blank 1 $'CAPTURE: REJECT [flat-capture]\nRESULT: FAIL' 0 FAIL
  capture_control strict-transparent 1 $'CAPTURE: REJECT [mostly-transparent]\nRESULT: FAIL' 0 FAIL
  capture_control allowed-transparent 1 $'CAPTURE: REJECT [mostly-transparent]\nRESULT: FAIL' 1 SKIP
  capture_control allowance-does-not-hide-blank 1 $'CAPTURE: REJECT [flat-capture]\nRESULT: FAIL' 1 FAIL
  capture_control allowance-does-not-hide-missing 1 $'CAPTURE: REJECT [unreadable-or-too-large]\nRESULT: FAIL' 1 FAIL
  capture_control pass-before-process-error 7 'RESULT: PASS' 0 FAIL
  if [[ "$passed" == "$total" ]]; then printf 'RESULT: PASS (%s/%s)\n' "$passed" "$total"; return 0
  else printf 'RESULT: FAIL (%s/%s)\n' "$passed" "$total"; return 1; fi
}

if [[ "${1:-}" == "--scenario-self-test" ]]; then
  scenario_self_test
  exit $?
fi

# scenario NAME  EXPECT_REGEX  -- command...
scenario() {
  local name="$1" expect="$2"; shift 2
  local out command_status
  out="$(timeout_run 120 "$@" 2>&1)"
  command_status=$?
  local result; result="$(grep -oE '^RESULT:.*' <<<"$out" | tail -1)"
  if scenario_succeeded "$command_status" "$out" "$expect"; then
    if grep -q '^RESULT: SKIP' <<<"$result"; then
      printf "  %sSKIP%s  %-34s %s%s%s\n" "$yellow" "$rst" "$name" "$dim" "${result#RESULT: }" "$rst"; skip=$((skip+1))
    else
      printf "  %s ok %s  %-34s %s%s%s\n" "$green" "$rst" "$name" "$dim" "${result#RESULT: }" "$rst"; pass=$((pass+1))
    fi
  else
    printf "  %sFAIL%s  %-34s\n" "$red" "$rst" "$name"; fail=$((fail+1))
    printf '        exit status: %s\n' "$command_status"
    sed 's/^/        /' <<<"$out" | tail -12
  fi
}

# A non-RESULT check (e.g. a file was produced).
assert() {
  local name="$1"; shift
  if "$@"; then printf "  %s ok %s  %s\n" "$green" "$rst" "$name"; pass=$((pass+1))
  else printf "  %sFAIL%s  %s\n" "$red" "$rst" "$name"; fail=$((fail+1)); fi
}

# Hardened Runtime holds for every build, including an ad-hoc dev build (package.sh signs
# with --options runtime regardless): a regression here would otherwise stay invisible
# until an actual notarization submission failed. Captures codesign's output before
# matching -- grep -q closing the pipe early would SIGPIPE codesign under pipefail.
hardened_runtime_enabled() {
  local cd_line
  cd_line="$(codesign -dv "$1" 2>&1 | grep '^CodeDirectory ')"
  [[ "$cd_line" =~ flags=0x[0-9a-f]+\([^\)]*runtime ]]
}

# Sparkle only ever reads these fields once an update is published, so a malformed one
# surfaces as "every user's auto-update silently does nothing" with no local signal.
sparkle_metadata_well_formed() {
  local plist="$1/Contents/Info.plist" feed version short minos
  feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist" 2>/dev/null)"
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null)"
  short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)"
  minos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null)"
  [[ "$feed" =~ ^https://.+/appcast\.xml$ ]] \
    && [[ "$version" =~ ^[0-9]+$ ]] \
    && [[ "$short" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
    && [[ "$minos" =~ ^[0-9]+(\.[0-9]+)*$ ]]
}

configuration_root_guard_probe() {
  local out command_status flag
  # A default invocation is safe against a release binary; debug flags must be explicit.
  local flags=(PATHEM_RELEASE_TEST)
  if [[ $# -gt 0 ]]; then flags=("$@"); fi
  for flag in "${flags[@]}"; do
    case "$flag" in PATHEM_CONTENT_PREFS_UI_TEST|PATHEM_SETTINGS_DEFAULTS_UI_TEST|PATHEM_OPENER_UI_TEST|PATHEM_SIDEBAR_TRANSFER_UI_TEST|PATHEM_FILE_SEARCH_TEST|PATHEM_LAYOUT_MATRIX_TEST|PATHEM_RELEASE_TEST) ;; *) printf 'RESULT: FAIL unknown guard flag\n'; return 2 ;; esac
    out="$(env -u PATHEM_CONFIG_DIR "$flag=1" "$BIN" 2>&1)"; command_status=$?
    if [[ "$command_status" != 64 || "$out" != 'RESULT: FAIL configuration test requires an isolated temporary config root' ]]; then
      printf 'RESULT: FAIL missing configuration root refusal for %s (exit %s)\n' "$flag" "$command_status"; return 1
    fi
    out="$(env PATHEM_CONFIG_DIR=/Applications "$flag=1" "$BIN" 2>&1)"; command_status=$?
    if [[ "$command_status" != 64 || "$out" != 'RESULT: FAIL configuration test refuses a non-temporary config root' ]]; then
      printf 'RESULT: FAIL unsafe configuration root refusal for %s (exit %s)\n' "$flag" "$command_status"; return 1
    fi
  done
  printf 'RESULT: PASS (%s/%s)\n' "$((2 * ${#flags[@]}))" "$((2 * ${#flags[@]}))"
}

# The timeout launcher execs an executable; a shell function name is not one.
if [[ "${1:-}" == "--configuration-root-guards" ]]; then
  BIN="${2:-}"
  [[ -x "$BIN" ]] || { printf 'RESULT: FAIL guard probe requires a binary\n'; exit 2; }
  configuration_root_guard_probe "${@:3}"
  exit $?
fi

# Release builds contain no debug scenario hooks. The explicit release-test mode isolates config.
# Probe the assembled product from
# outside: launch the real binary, require it to stay alive, and inspect its on-screen window by
# owner PID through read-only Core Graphics metadata (no Accessibility permission required).
packaged_launch_probe() {
  local log="${TMPDIR:-/tmp}/pathem-packaged-e2e.log"
  : > "$log"
  env PATHEM_RELEASE_TEST=1 "$BIN" >"$log" 2>&1 &
  local pid=$!
  local alive=0
  for _ in {1..20}; do
    if kill -0 "$pid" 2>/dev/null; then alive=1; sleep 0.25; else break; fi
  done
  if [[ $alive == 1 ]] && kill -0 "$pid" 2>/dev/null; then
    printf "  %s ok %s  %-34s %sprocess %s stayed alive%s\n" "$green" "$rst" "release app launches" "$dim" "$pid" "$rst"
    pass=$((pass+1))
  else
    printf "  %sFAIL%s  %-34s\n" "$red" "$rst" "release app launches"
    tail -12 "$log" | sed 's/^/        /'
    fail=$((fail+1))
  fi

  local windows=""
  windows="$(timeout_run 20 xcrun --toolchain XcodeDefault swift \
    "$ROOT/test/e2e/window_probe.swift" "$pid" 2>/dev/null || true)"
  if [[ "$windows" =~ ^[1-9][0-9]*$ ]]; then
    printf "  %s ok %s  %-34s %s%s visible window(s)%s\n" "$green" "$rst" "release visible window" "$dim" "$windows" "$rst"
    pass=$((pass+1))
  else
    printf "  %sFAIL%s  %-34s %swindow count: %s%s\n" "$red" "$rst" "release visible window" "$dim" "${windows:-unavailable}" "$rst"
    fail=$((fail+1))
  fi

  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert "release config written in scratch" test -f "$PATHEM_CONFIG_DIR/prefs.json"
  # The probe shares the owner app's bundle ID: a running Sparkle updater would fetch the feed
  # and write its state into the owner's real defaults.
  assert "release probe keeps the updater off" grep -q '^UPDATER: disabled for release test$' "$log"
}

echo "==> Building product"
if [[ $PACKAGED == 1 ]]; then
  PACKAGE_LOG="$E2E_SCRATCH/package-build.log"
  INSTALL= ./scripts/package.sh >"$PACKAGE_LOG" 2>&1 \
    || { echo "${red}package.sh failed${rst}"; tail -8 "$PACKAGE_LOG"; exit 1; }
  cp "$PACKAGE_LOG" "$ROOT/.build/ci-release-build.log"
  python3 scripts/check_warnings.py "$PACKAGE_LOG" || exit 1
  APP="$ROOT/.build/Pathem.app"
  BIN="$APP/Contents/MacOS/Pathem"
  echo "==> Packaged app: $APP"
  # Bundle-completeness checks (a missing resource bundle is what crashed launch).
  assert "binary present"        test -x "$BIN"
  assert "resource bundle present" test -d "$APP/Contents/Resources/Pathem_Pathem.bundle"
  assert "torrent daemon bundled" test -x "$APP/Contents/MacOS/pathem-torrentd"
  assert "AFC helper bundled"     test -x "$APP/Contents/MacOS/pathem-afc"
  assert "CLI bundled"            test -x "$APP/Contents/MacOS/pathem-cli"
  langs=$(ls -d "$APP/Contents/Resources/Pathem_Pathem.bundle/"*.lproj 2>/dev/null | wc -l | tr -d ' ')
  assert "all 6 languages bundled ($langs)" test "$langs" -eq 6
  assert "bundle signature verifies" codesign --verify --deep --strict "$APP"
  assert "hardened runtime enabled" hardened_runtime_enabled "$BIN"
  assert "Sparkle update metadata well-formed" sparkle_metadata_well_formed "$APP"
  # Universal isn't forced here (every arch doubles this build's time, a cost tradeoff
  # for CI minutes, not an engineering call); report what was actually produced, and only
  # turn it into a failure if the caller explicitly asked ARCHS for more than one.
  main_archs="$(lipo -archs "$BIN" 2>/dev/null)"
  echo "    main executable architectures: ${main_archs:-unknown}"
  if [[ "${ARCHS:-}" == *" "* ]]; then
    missing_archs=""
    for wanted_arch in $ARCHS; do
      [[ " $main_archs " == *" $wanted_arch "* ]] || missing_archs+=" $wanted_arch"
    done
    assert "requested architectures present ($ARCHS)" test -z "$missing_archs"
  fi
  scenario "release configuration-root guards" 'RESULT: PASS' "$ROOT/test/e2e/run.sh" --configuration-root-guards "$BIN" PATHEM_RELEASE_TEST
  packaged_launch_probe
  echo
  echo "==> ${pass} passed, ${skip} skipped, ${fail} failed"
  [[ $fail -eq 0 ]]
  exit
else
  swift build --build-system native >/tmp/pathem_e2e_build.log 2>&1 \
    || { echo "${red}swift build failed${rst}"; tail -8 /tmp/pathem_e2e_build.log; exit 1; }
  BIN="$(swift build --build-system native --show-bin-path)/Pathem"
fi

echo "==> Scenarios"
CAPTURE_CHECKER="$E2E_SCRATCH/capture-quality"
xcrun --toolchain XcodeDefault swiftc -swift-version 6 test/e2e/capture_quality.swift \
  -o "$CAPTURE_CHECKER" >"$E2E_SCRATCH/capture-build.log" 2>&1 \
  || { tail -30 "$E2E_SCRATCH/capture-build.log"; exit 1; }
python3 scripts/check_warnings.py "$E2E_SCRATCH/capture-build.log" || exit 1
scenario "capture discrimination controls" 'RESULT: PASS' "$CAPTURE_CHECKER" --self-test
scenario "E2E completion controls" 'RESULT: PASS' "$ROOT/test/e2e/run.sh" --scenario-self-test
scenario "launch + UI invariants"      'RESULT: PASS' env PATHEM_SMOKE=1 "$BIN"
scenario "1M-row virtualization (Gate A)" 'RESULT: PASS' env PATHEM_GATE_A=1 "$BIN"
scenario "localization bundled + resolves" 'RESULT: PASS' env PATHEM_L10N_SMOKE=1 "$BIN"
scenario "organize-with-AI path"       'RESULT: (PASS|SKIP)' env PATHEM_AI_SMOKE=1 "$BIN"
scenario "torrent + magnet daemon seam" 'RESULT: PASS' env PATHEM_TORRENTS_SMOKE=1 "$BIN"
scenario "create + rename flow (real files)" 'RESULT: PASS' env PATHEM_E2E=1 "$BIN"
scenario "on-screen UI interactions"   'RESULT: PASS' env PATHEM_UI_TEST=1 "$BIN"
scenario "file search UI + scopes"     'RESULT: PASS' env PATHEM_CONFIG_DIR="$E2E_SCRATCH/search-config" PATHEM_FILE_SEARCH_TEST=1 "$BIN"
scenario "Finder actions across views" 'RESULT: PASS' env PATHEM_FINDER_UI_TEST=1 "$BIN"
scenario "background view + arrange menus" 'RESULT: PASS' env PATHEM_BACKGROUND_UI_TEST=1 "$BIN"
scenario "sidebar paste + drag preferences" 'RESULT: PASS' env PATHEM_CONFIG_DIR="$E2E_SCRATCH/sidebar-transfer-config" PATHEM_SIDEBAR_TRANSFER_UI_TEST=1 "$BIN"
scenario "configuration-root refusal guards" 'RESULT: PASS' "$ROOT/test/e2e/run.sh" --configuration-root-guards "$BIN" PATHEM_CONTENT_PREFS_UI_TEST PATHEM_SETTINGS_DEFAULTS_UI_TEST PATHEM_OPENER_UI_TEST PATHEM_SIDEBAR_TRANSFER_UI_TEST PATHEM_FILE_SEARCH_TEST PATHEM_LAYOUT_MATRIX_TEST PATHEM_RELEASE_TEST
scenario "pane configuration + real tabs" 'RESULT: PASS' env PATHEM_CONFIG_DIR="$E2E_SCRATCH/content-prefs-config" PATHEM_CONTENT_PREFS_UI_TEST=1 "$BIN"
scenario "gallery rules + initial defaults" 'RESULT: PASS' env PATHEM_CONFIG_DIR="$E2E_SCRATCH/gallery-prefs-config" PATHEM_CONTENT_PREFS_UI_TEST=1 PATHEM_CONTENT_PREFS_GALLERY_SAMPLE=1 "$BIN"
scenario "settings defaults + startup stores" 'RESULT: PASS' env PATHEM_CONFIG_DIR="$E2E_SCRATCH/settings-defaults-config" PATHEM_SETTINGS_DEFAULTS_UI_TEST=1 "$BIN"
scenario "Always Open With application picker" 'RESULT: PASS' env PATHEM_CONFIG_DIR="$E2E_SCRATCH/opener-config" PATHEM_OPENER_UI_TEST=1 "$BIN"
scenario "layout + listing boundaries" 'RESULT: PASS' env PATHEM_LAYOUT_UI_TEST=1 "$BIN"
scenario "transient controls + cancel" 'RESULT: PASS' env PATHEM_TRANSIENT_UI_TEST=1 "$BIN"
scenario "compiler-sensitive Arrange menu" 'RESULT: PASS' env PATHEM_COMPILER_UI_TEST=1 "$BIN"
scenario "media trim export + rejection" 'RESULT: PASS' env PATHEM_TRIM_SMOKE=1 "$BIN"
scenario "file conflicts + undo/redo/trash" 'RESULT: PASS' env PATHEM_FILES_E2E=1 "$BIN"
scenario "advanced filesystem tools"   'RESULT: PASS' env PATHEM_ADVANCED_FILES_E2E=1 "$BIN"
scenario "archives + disk utilities"   'RESULT: PASS' env PATHEM_ARCHIVES_E2E=1 "$BIN"
scenario "search + tags + metadata"    'RESULT: PASS' env PATHEM_SEARCH_METADATA_E2E=1 "$BIN"
scenario "Git + external commands"     'RESULT: PASS' env PATHEM_DEVELOPER_E2E=1 "$BIN"

# Real WebDAV CRUD through the app -> provider -> system curl boundary, backed by a hermetic
# loopback fixture rather than a public service or user-owned credentials.
WEBDAV_ROOT="$E2E_SCRATCH/webdav-root"
WEBDAV_PORT_FILE="$E2E_SCRATCH/webdav-port"
/usr/bin/python3 "$ROOT/test/e2e/webdav_fixture.py" \
  --root "$WEBDAV_ROOT" --port-file "$WEBDAV_PORT_FILE" &
WEBDAV_PID=$!
for _ in {1..100}; do
  [[ -s "$WEBDAV_PORT_FILE" ]] && break
  kill -0 "$WEBDAV_PID" 2>/dev/null || break
  sleep 0.02
done
if [[ -s "$WEBDAV_PORT_FILE" ]]; then
  WEBDAV_PORT="$(<"$WEBDAV_PORT_FILE")"
  scenario "loopback WebDAV CRUD" 'RESULT: PASS' env PATHEM_WEBDAV_E2E=1 PATHEM_WEBDAV_PORT="$WEBDAV_PORT" "$BIN"
else
  printf "  %sFAIL%s  %-34s\n" "$red" "$rst" "loopback WebDAV fixture starts"
  fail=$((fail+1))
fi

# Exercise both signed object-storage backends over real TLS without requiring cloud accounts.
# The generated CA is scoped to this process invocation and disappears with the scratch folder.
OBJECT_STORAGE_ROOT="$E2E_SCRATCH/object-storage-root"
OBJECT_STORAGE_PORT_FILE="$E2E_SCRATCH/object-storage-port"
OBJECT_STORAGE_CERT="$E2E_SCRATCH/object-storage-cert.pem"
OBJECT_STORAGE_KEY="$E2E_SCRATCH/object-storage-key.pem"
if /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=127.0.0.1' -addext 'subjectAltName=IP:127.0.0.1' \
  -keyout "$OBJECT_STORAGE_KEY" -out "$OBJECT_STORAGE_CERT" \
  >"$E2E_SCRATCH/object-storage-openssl.log" 2>&1; then
  /usr/bin/python3 "$ROOT/test/e2e/object_storage_fixture.py" \
    --root "$OBJECT_STORAGE_ROOT" --port-file "$OBJECT_STORAGE_PORT_FILE" \
    --cert "$OBJECT_STORAGE_CERT" --key "$OBJECT_STORAGE_KEY" &
  OBJECT_STORAGE_PID=$!
  for _ in {1..100}; do
    [[ -s "$OBJECT_STORAGE_PORT_FILE" ]] && break
    kill -0 "$OBJECT_STORAGE_PID" 2>/dev/null || break
    sleep 0.02
  done
fi
if [[ -s "$OBJECT_STORAGE_PORT_FILE" ]]; then
  OBJECT_STORAGE_PORT="$(<"$OBJECT_STORAGE_PORT_FILE")"
  scenario "loopback S3 + Azure CRUD" 'RESULT: PASS' env \
    CURL_CA_BUNDLE="$OBJECT_STORAGE_CERT" SSL_CERT_FILE="$OBJECT_STORAGE_CERT" \
    PATHEM_OBJECT_STORAGE_E2E=1 PATHEM_OBJECT_STORAGE_PORT="$OBJECT_STORAGE_PORT" "$BIN"
else
  printf "  %sFAIL%s  %-34s\n" "$red" "$rst" "loopback object-storage fixture starts"
  fail=$((fail+1))
fi

# Cached pixels are evidence only after decoding and discrimination. A renderer that cannot
# composite native materials earns an explicit SKIP for visual acceptance, never a false PASS.
verify_cached_capture() {
  local name="$1" path="$2" allow_transparency="${3:-0}" out status disposition
  out="$("$CAPTURE_CHECKER" "$path" 2>&1)"; status=$?
  disposition="$(capture_disposition "$status" "$out" "$allow_transparency")"
  if [[ "$disposition" == PASS ]]; then
    printf '  %s ok %s  %s (pixel sanity only)\n' "$green" "$rst" "$name"; pass=$((pass+1))
  elif [[ "$disposition" == SKIP ]]; then
    printf '  %sSKIP%s  %s (cached pixels rejected; native appearance unverified)\n' "$yellow" "$rst" "$name"
    sed 's/^/        /' <<<"$out"; skip=$((skip+1))
  else
    printf '  %sFAIL%s  %s (capture pipeline)\n' "$red" "$rst" "$name"
    sed 's/^/        /' <<<"$out"; fail=$((fail+1))
  fi
}
timeout_run 120 env PATHEM_PREFS_SHOT=1 "$BIN" >"$E2E_SCRATCH/prefs.log" 2>&1
prefs_status=$?
assert "settings capture process exits" test "$prefs_status" -eq 0
timeout_run 120 env PATHEM_SIDEBAR_SHOT=1 "$BIN" >"$E2E_SCRATCH/sidebar.log" 2>&1
sidebar_status=$?
assert "sidebar capture process exits" test "$sidebar_status" -eq 0
verify_cached_capture "settings pixels" "$PATHEM_CAPTURE_DIR/settings_general.png"
verify_cached_capture "sidebar pixels" "$PATHEM_CAPTURE_DIR/sidebar.png"
verify_cached_capture "browser flow pixels" "$PATHEM_CAPTURE_DIR/pathem-e2e.png" 1

# Bounded representative theme/locale/long-label matrix, not an approved golden corpus.
for appearance in light dark; do
  for language in en de; do
    for long_labels in 0 1; do
      name="conflict $appearance/$language/long=$long_labels"
      capture_dir="$PATHEM_CAPTURE_DIR/$appearance-$language-$long_labels"
      mkdir -p "$capture_dir"
      timeout_run 120 env PATHEM_CONFLICT_SHOT=1 PATHEM_CAPTURE_DIR="$capture_dir" \
        PATHEM_CAPTURE_APPEARANCE="$appearance" PATHEM_CAPTURE_LONG_LABELS="$long_labels" \
        "$BIN" -AppleLanguages "($language)" >"$capture_dir/delivery.log" 2>&1
      capture_status=$?
      assert "$name process exits" test "$capture_status" -eq 0
      expected_appearance=NSAppearanceNameAqua
      [[ "$appearance" == dark ]] && expected_appearance=NSAppearanceNameDarkAqua
      assert "$name appearance + language delivered" \
        grep -q "appearance=$expected_appearance language=$language" "$capture_dir/delivery.log"
      if [[ "$long_labels" == 0 ]]; then
        expected_label=Replace
        [[ "$language" == de ]] && expected_label=Ersetzen
        assert "$name translated action delivered" grep -q "buttons=$expected_label |" "$capture_dir/delivery.log"
      else
        assert "$name long labels delivered" grep -q 'buttons=Vorhandene Datei vollständig ersetzen |' "$capture_dir/delivery.log"
      fi
      verify_cached_capture "$name pixels" "$capture_dir/conflict.png"
    done
  done
done
invalid_dir="$PATHEM_CAPTURE_DIR/invalid"
mkdir -p "$invalid_dir"
timeout_run 120 env PATHEM_CONFLICT_SHOT=1 PATHEM_CAPTURE_DIR="$invalid_dir" \
  PATHEM_CAPTURE_APPEARANCE=invalid "$BIN" >"$invalid_dir/delivery.log" 2>&1
invalid_status=$?
assert "unsupported appearance refused" test "$invalid_status" -eq 64
assert "unsupported appearance writes no PNG" test ! -e "$invalid_dir/conflict.png"

echo
echo "==> ${pass} passed, ${skip} skipped, ${fail} failed"
[[ $fail -eq 0 ]]
