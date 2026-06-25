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
  langs=$(ls -d "$APP/Contents/Resources/Pathem_Pathem.bundle/"*.lproj 2>/dev/null | wc -l | tr -d ' ')
  assert "all 6 languages bundled ($langs)" test "$langs" -eq 6
else
  swift build >/tmp/pathem_e2e_build.log 2>&1 \
    || { echo "${red}swift build failed${rst}"; tail -8 /tmp/pathem_e2e_build.log; exit 1; }
  BIN="$(swift build --show-bin-path)/Pathem"
fi

echo "==> Scenarios"
scenario "launch + UI invariants"      'RESULT: PASS' env PATHEM_SMOKE=1 "$BIN"
scenario "1M-row virtualization (Gate A)" 'RESULT: PASS' env PATHEM_GATE_A=1 "$BIN"
scenario "localization bundled + resolves" 'RESULT: PASS' env PATHEM_L10N_SMOKE=1 "$BIN"
scenario "organize-with-AI path"       'RESULT: (PASS|SKIP)' env PATHEM_AI_SMOKE=1 "$BIN"

# Render harnesses: assert they produce non-empty PNGs (layout didn't collapse).
rm -f /tmp/settings_general.png /tmp/sidebar.png
env PATHEM_PREFS_SHOT=1 "$BIN" >/dev/null 2>&1
env PATHEM_SIDEBAR_SHOT=1 "$BIN" >/dev/null 2>&1
assert "settings panes render"  test -s /tmp/settings_general.png
assert "sidebar renders"        test -s /tmp/sidebar.png

echo
echo "==> ${pass} passed, ${skip} skipped, ${fail} failed"
[[ $fail -eq 0 ]]
