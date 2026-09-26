#!/usr/bin/env bash
#
# Blackbox end-to-end harness for Pathem.
#
# Launches the REAL built product and asserts behavior from the outside (no access to
# internals): the app launches without crashing, the dense list virtualizes a 1M-row
# directory, localized resources are bundled and resolve, the on-device AI path runs,
# and key panels lay out. Each scenario is driven by a PATHEM_* environment switch the
# app understands and prints a "RESULT: PASS/SKIP/FAIL" line we grep for.
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
cleanup() {
  if [[ -n "$WEBDAV_PID" ]]; then
    kill -TERM "$WEBDAV_PID" 2>/dev/null || true
    wait "$WEBDAV_PID" 2>/dev/null || true
  fi
  rm -rf "$E2E_SCRATCH"
}
trap cleanup EXIT
export PATHEM_CONFIG_DIR="$E2E_SCRATCH/config"

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

# scenario NAME  EXPECT_REGEX  -- command...
scenario() {
  local name="$1" expect="$2"; shift 2
  local out
  out="$(timeout_run 120 "$@" 2>&1)"
  local result; result="$(grep -oE 'RESULT:.*' <<<"$out" | head -1)"
  if grep -qE "$expect" <<<"$out"; then
    if grep -q 'RESULT: SKIP' <<<"$out"; then
      printf "  %sSKIP%s  %-34s %s%s%s\n" "$yellow" "$rst" "$name" "$dim" "${result#RESULT: }" "$rst"; skip=$((skip+1))
    else
      printf "  %s ok %s  %-34s %s%s%s\n" "$green" "$rst" "$name" "$dim" "${result#RESULT: }" "$rst"; pass=$((pass+1))
    fi
  else
    printf "  %sFAIL%s  %-34s\n" "$red" "$rst" "$name"; fail=$((fail+1))
    sed 's/^/        /' <<<"$out" | tail -12
  fi
}

# A non-RESULT check (e.g. a file was produced).
assert() {
  local name="$1"; shift
  if "$@"; then printf "  %s ok %s  %s\n" "$green" "$rst" "$name"; pass=$((pass+1))
  else printf "  %sFAIL%s  %s\n" "$red" "$rst" "$name"; fail=$((fail+1)); fi
}

# Release builds intentionally contain no PATHEM_* debug hooks. Probe the assembled product from
# outside: launch the real binary, require it to stay alive, and inspect its window through macOS
# Accessibility when the invoking terminal/runner has that permission.
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
  windows="$(timeout_run 10 osascript \
    -e 'tell application "System Events" to tell process "Pathem" to count windows' 2>/dev/null || true)"
  if [[ "$windows" =~ ^[1-9][0-9]*$ ]]; then
    printf "  %s ok %s  %-34s %s%s visible window(s)%s\n" "$green" "$rst" "release accessibility surface" "$dim" "$windows" "$rst"
    pass=$((pass+1))
  else
    printf "  %sSKIP%s  %-34s %sgrant Accessibility to run this assertion%s\n" "$yellow" "$rst" "release accessibility surface" "$dim" "$rst"
    skip=$((skip+1))
  fi

  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

echo "==> Building product"
if [[ $PACKAGED == 1 ]]; then
  INSTALL= ./scripts/package.sh >/tmp/pathem_e2e_pkg.log 2>&1 \
    || { echo "${red}package.sh failed${rst}"; tail -8 /tmp/pathem_e2e_pkg.log; exit 1; }
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
scenario "launch + UI invariants"      'RESULT: PASS' env PATHEM_SMOKE=1 "$BIN"
scenario "1M-row virtualization (Gate A)" 'RESULT: PASS' env PATHEM_GATE_A=1 "$BIN"
scenario "localization bundled + resolves" 'RESULT: PASS' env PATHEM_L10N_SMOKE=1 "$BIN"
scenario "organize-with-AI path"       'RESULT: (PASS|SKIP)' env PATHEM_AI_SMOKE=1 "$BIN"
scenario "torrent + magnet daemon seam" 'RESULT: PASS' env PATHEM_TORRENTS_SMOKE=1 "$BIN"
rm -f /tmp/pathem-e2e.png  # cleared before the flow so the render assert below sees a fresh one
scenario "create + rename flow (real files)" 'RESULT: PASS' env PATHEM_E2E=1 "$BIN"
scenario "on-screen UI interactions"   'RESULT: PASS' env PATHEM_UI_TEST=1 "$BIN"
scenario "file conflicts + undo/redo/trash" 'RESULT: PASS' env PATHEM_FILES_E2E=1 "$BIN"
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

# Render harnesses: assert they produce non-empty PNGs (layout didn't collapse).
rm -f /tmp/settings_general.png /tmp/sidebar.png
env PATHEM_PREFS_SHOT=1 "$BIN" >/dev/null 2>&1
env PATHEM_SIDEBAR_SHOT=1 "$BIN" >/dev/null 2>&1
assert "settings panes render"  test -s /tmp/settings_general.png
assert "sidebar renders"        test -s /tmp/sidebar.png
assert "e2e flow render produced" test -s /tmp/pathem-e2e.png

echo
echo "==> ${pass} passed, ${skip} skipped, ${fail} failed"
[[ $fail -eq 0 ]]
