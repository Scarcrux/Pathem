#!/usr/bin/env bash
# Record the 1,000,000-row scroll demo (the above-the-fold asset) to a video, and to an
# optimized GIF if ffmpeg is installed. The app auto-scrolls the full million rows smoothly;
# `make gate-a` proves the same dataset only materializes ~90 cells.
#
# Requires Screen Recording permission for your terminal: System Settings > Privacy &
# Security > Screen Recording. The first run prompts; grant it, then run again.
#
# Usage: scripts/capture-gate-a.sh [seconds]   (default 12)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEN="${1:-12}"
OUT_DIR="$ROOT/docs/demo"
MOV="$OUT_DIR/gate-a-1M.mov"
GIF="$OUT_DIR/gate-a-1M.gif"
mkdir -p "$OUT_DIR"

echo "==> Building"
( cd "$ROOT" && swift build >/dev/null )

echo "==> Launching the 1M-row scroll demo (${LEN}s)"
PATHEM_GATE_A_DEMO=1 PATHEM_GATE_A_SECONDS="$LEN" "$ROOT/.build/debug/Pathem" &
APP_PID=$!
sleep 2  # let the window appear and the rows build before recording

echo "==> Recording the screen to $MOV"
echo "    (if this is black or errors, grant Screen Recording to your terminal and re-run)"
screencapture -v -V"$LEN" "$MOV" || true
wait "$APP_PID" 2>/dev/null || true

if command -v ffmpeg >/dev/null 2>&1; then
  echo "==> Converting to an optimized GIF: $GIF"
  ffmpeg -y -i "$MOV" \
    -vf "fps=20,scale=1000:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" \
    "$GIF" >/dev/null 2>&1
  echo "==> Done: $GIF (raw video kept at $MOV)"
else
  echo "==> Kept $MOV. Install ffmpeg (brew install ffmpeg) to also produce a GIF."
fi
echo "    Crop/trim to the window, then reference it above the fold in README.md and site/."
