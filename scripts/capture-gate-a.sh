#!/usr/bin/env bash
# Record the 1,000,000-row scroll demo (the above-the-fold asset) to a video, and to an
# optimized GIF if ffmpeg is installed. The app auto-scrolls the full million rows smoothly;
# `make gate-a` proves the same dataset only materializes ~90 cells.
#
# Requires Screen Recording permission for the host running this script (for example,
# Commandem or Terminal): System Settings > Privacy & Security > Screen & System Audio
# Recording. The script fails before building when that permission is missing.
#
# Usage: scripts/capture-gate-a.sh [seconds]   (default 12)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEN="${1:-12}"
OUT_DIR="$ROOT/docs/demo"
MOV="$OUT_DIR/gate-a-1M.mov"
GIF="$OUT_DIR/gate-a-1M.gif"
mkdir -p "$OUT_DIR"

XCODE_SWIFT="$(xcrun --toolchain XcodeDefault --find swift)"
"$ROOT/scripts/toolchain_preflight.sh"

if [[ "$("$XCODE_SWIFT" -e 'import CoreGraphics; print(CGPreflightScreenCaptureAccess() ? "yes" : "no")')" != "yes" ]]; then
  echo "error: Screen Recording permission is not granted to this host." >&2
  echo "Open System Settings > Privacy & Security > Screen & System Audio Recording," >&2
  echo "enable Commandem (or the terminal running make), restart it, and run make gate-a-demo again." >&2
  exit 77
fi

echo "==> Building"
( cd "$ROOT" && "$XCODE_SWIFT" build --build-system native >/dev/null )

echo "==> Launching the 1M-row scroll demo (${LEN}s)"
PATHEM_GATE_A_DEMO=1 PATHEM_GATE_A_SECONDS="$LEN" "$ROOT/.build/debug/Pathem" &
APP_PID=$!
sleep 2  # let the window appear and the rows build before recording

WINDOW_ID="$("$XCODE_SWIFT" -e '
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else { exit(2) }
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
let match = windows
    .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    .max {
        let a = CGRect(dictionaryRepresentation: $0[kCGWindowBounds as String] as! CFDictionary)?.width ?? 0
        let b = CGRect(dictionaryRepresentation: $1[kCGWindowBounds as String] as! CFDictionary)?.width ?? 0
        return a < b
    }
guard let number = match?[kCGWindowNumber as String] as? UInt32 else { exit(3) }
print(number)
' "$APP_PID")"

if [[ -z "$WINDOW_ID" ]]; then
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  echo "error: the Gate A window did not become observable" >&2
  exit 1
fi

echo "==> Recording Pathem window $WINDOW_ID to $MOV"
screencapture -l"$WINDOW_ID" -v -V"$LEN" "$MOV"
wait "$APP_PID" 2>/dev/null || true
test -s "$MOV"

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
