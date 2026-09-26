#!/usr/bin/env bash
#
# Watch the sources and rebuild + relaunch Pathem on every change, so you don't
# have to do it by hand. Two modes:
#
#   scripts/watch.sh            fast loop: debug build, launched from .build.
#                               Rebuilds in ~1s. Full Disk Access does NOT
#                               persist for this unsigned build, but browsing
#                               your home folder doesn't need it, so this is the
#                               right mode for UI work.
#   scripts/watch.sh install    full loop: build + sign + install the .app to
#                               /Applications and relaunch. Signs with the stable
#                               "Pathem Self-Signed" identity if it exists (run
#                               `make dev-cert` to create it) so a Full Disk
#                               Access grant survives rebuilds; otherwise signs
#                               ad-hoc. Slower (universal release build each time).
#
# Press Ctrl-C to stop; the copy of Pathem this script launched is terminated too
# (in install mode the installed app is quit). Install fswatch (brew install
# fswatch) for instant rebuilds; otherwise the script polls once a second. A
# failed build leaves the last good copy running.

set -uo pipefail  # deliberately no -e: a failed build must not kill the loop

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
"$ROOT/scripts/toolchain_preflight.sh" || exit 1
MODE="${1:-run}"
APP_PID=""
FSWATCH_PID=""

# Install mode: use the stable self-signed identity only if it actually exists,
# otherwise sign ad-hoc so a fresh checkout still works (just without persistent
# Full Disk Access). package.sh reads SIGN_IDENTITY from the environment.
if [[ "$MODE" == "install" && -z "${SIGN_IDENTITY:-}" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -qF "Pathem Self-Signed"; then
    export SIGN_IDENTITY="Pathem Self-Signed"
  else
    echo "    note: no 'Pathem Self-Signed' identity; signing ad-hoc."
    echo "          run 'make dev-cert' once to keep a Full Disk Access grant across rebuilds."
  fi
fi

kill_app() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then kill "$APP_PID" 2>/dev/null || true; fi
  APP_PID=""
  if [[ "$MODE" == "install" ]]; then
    pkill -f "/Applications/Pathem.app/Contents/MacOS/Pathem" 2>/dev/null || true
  fi
}

cleanup() {
  kill_app
  if [[ -n "$FSWATCH_PID" ]] && kill -0 "$FSWATCH_PID" 2>/dev/null; then kill "$FSWATCH_PID" 2>/dev/null || true; fi
  exit 0
}
trap cleanup INT TERM

launch() {
  if [[ "$MODE" == "install" ]]; then
    # package.sh quits any running copy, installs, then we reopen it.
    if INSTALL=1 scripts/package.sh; then
      open "/Applications/Pathem.app"
    else
      echo "==> package/sign/install failed (see output above); keeping the running copy" >&2
    fi
    return
  fi

  # Fast loop: build first; only swap the running instance if the build worked.
  if swift build --build-system native; then
    kill_app
    local bin
    bin="$(swift build --build-system native --show-bin-path)/Pathem"
    "$bin" &
    APP_PID=$!
  else
    echo "==> build failed; keeping the running copy" >&2
  fi
}

# A content signature of the watched files. %Fm is the nanosecond-resolution
# mtime and %z the size, so two saves within the same wall-clock second are still
# seen as distinct (a whole-second mtime would silently drop the second save).
signature() {
  find Sources Tests Package.swift -type f -name '*.swift' \
    -exec stat -f '%Fm %z %N' {} + 2>/dev/null | sort | shasum | awk '{print $1}'
}

# Read fswatch events until it stops; returns so the caller can fall back to
# polling rather than silently leaving the app stale.
run_fswatch() {
  local fifo
  fifo="$(mktemp -u)" && mkfifo "$fifo" || return 1
  fswatch -o Sources Tests Package.swift > "$fifo" 2>/dev/null &
  FSWATCH_PID=$!
  while read -r _; do
    echo "==> change detected, rebuilding…"
    launch
  done < "$fifo"
  rm -f "$fifo"
  FSWATCH_PID=""
}

poll() {
  echo "    (tip: brew install fswatch for instant rebuilds; polling once a second)"
  local last cur
  last="$(signature)"
  while true; do
    sleep 1
    cur="$(signature)"
    if [[ "$cur" != "$last" ]]; then
      last="$cur"
      echo "==> change detected, rebuilding…"
      launch
    fi
  done
}

echo "==> Pathem watch ($MODE). Ctrl-C to stop."
launch

if command -v fswatch >/dev/null 2>&1; then
  run_fswatch
  echo "==> fswatch stopped; switching to polling" >&2
fi
poll
