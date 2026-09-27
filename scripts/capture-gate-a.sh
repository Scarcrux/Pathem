#!/usr/bin/env bash
# Render the 1,000,000-row scroll demo (the above-the-fold asset) to an MP4 and optimized GIF.
# Pathem renders its own window to PNG frames, so no Screen Recording permission is needed.
# `make gate-a` proves the same dataset only materializes ~90 cells.
#
# Usage: scripts/capture-gate-a.sh [seconds]   (default 10)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEN="${1:-10}"
OUT_DIR="$ROOT/docs/demo"
VIDEO="$ROOT/site/assets/gate-a-1M.mp4"
GIF="$OUT_DIR/gate-a-1M.gif"
mkdir -p "$OUT_DIR" "$(dirname "$VIDEO")"

FRAMES_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pathem-gate-a-frames.XXXXXX")"
APP_PID=""
cleanup() {
  if [[ -n "$APP_PID" ]]; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  if [[ "$FRAMES_DIR" == *pathem-gate-a-frames.* ]]; then rm -rf "$FRAMES_DIR"; fi
}
trap cleanup EXIT

XCODE_SWIFT="$(xcrun --toolchain XcodeDefault --find swift)"
"$ROOT/scripts/toolchain_preflight.sh"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "error: ffmpeg is required to encode the in-process frames (brew install ffmpeg)." >&2
  exit 1
fi

echo "==> Building"
( cd "$ROOT" && "$XCODE_SWIFT" build --build-system native >/dev/null )

echo "==> Rendering the 1M-row scroll demo (${LEN}s, no Screen Recording permission needed)"
PATHEM_GATE_A_DEMO=1 PATHEM_GATE_A_SECONDS="$LEN" PATHEM_GATE_A_FRAMES_DIR="$FRAMES_DIR" \
  "$ROOT/.build/debug/Pathem" &
APP_PID=$!
wait "$APP_PID"
APP_PID=""

FRAME_COUNT="$(find "$FRAMES_DIR" -maxdepth 1 -name 'frame-*.png' | wc -l | tr -d ' ')"
if [[ "$FRAME_COUNT" -lt 2 ]]; then
  echo "error: Pathem rendered only $FRAME_COUNT frame(s)." >&2
  exit 1
fi
FPS="$(awk -v frames="$FRAME_COUNT" -v seconds="$LEN" 'BEGIN { printf "%.3f", frames / seconds }')"

echo "==> Encoding $FRAME_COUNT frames at ${FPS}fps to $VIDEO"
ffmpeg -y -framerate "$FPS" -i "$FRAMES_DIR/frame-%05d.png" \
  -vf "scale=1000:-2:flags=lanczos" -c:v libx264 -preset slow -crf 24 -pix_fmt yuv420p \
  -movflags +faststart "$VIDEO" >/dev/null 2>&1

echo "==> Encoding optimized GIF to $GIF"
ffmpeg -y -framerate "$FPS" -i "$FRAMES_DIR/frame-%05d.png" \
  -vf "scale=720:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=96[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3" \
  "$GIF" >/dev/null 2>&1

test -s "$VIDEO"
test -s "$GIF"
echo "==> Done: $VIDEO and $GIF"
