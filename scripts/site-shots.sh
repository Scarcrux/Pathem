#!/bin/zsh
#
# Capture the website and README screenshots from the real app over the demo workspace.
#
#   scripts/site-shots.sh [output-dir] [name ...]
#
# Each shot launches the debug build with PATHEM_DEMO=1 and PATHEM_SITE_SHOT=<name> (see
# BrowserViewController+SiteShots.swift) under a throwaway config directory, lets it stage
# the composition and take a composited capture of its own window, then quits. Nothing from
# the real home folder or preferences is on screen.
#
# screencapture needs the Screen Recording right. A shell hosted inside another app may not
# have it; in that case run this script from Terminal (for example
# `open -a Terminal scripts/site-shots.command`, a two-line wrapper that calls it).
#
# Images are captured at the display's own scale. On a 1x display, switch to a scaled
# HiDPI mode first (scripts/display-mode.swift) to get 2x output, and switch back after.
# A capture taken while the window was not active (grey traffic lights) is retried.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/debug/Pathem"
OUT="${1:-$ROOT/.build/site-shots}"
shift 2>/dev/null || true
NAMES=("$@")
[[ ${#NAMES[@]} -eq 0 ]] && NAMES=(hero list icons gallery columns tree terminal torrent remote markup)
SIZE="${PATHEM_SITE_SIZE:-1440x900}"
[[ -x "$BIN" ]] || { echo "build first: swift build"; exit 1; }
mkdir -p "$OUT"
TMP="$(getconf DARWIN_USER_TEMP_DIR)"
failed=0
for name in "${NAMES[@]}"; do
	extra=()
	[[ "$name" == torrent ]] && extra+=(PATHEM_DEMO_TORRENTS=1)
	[[ "$name" == terminal ]] && extra+=(PATHEM_SITE_SETTLE=9)
	ok=0
	for attempt in 1 2 3; do
		cfg="${TMP}pathem-site-shot-config"
		/bin/rm -rf "$cfg"; mkdir -p "$cfg"
		print -r -- '{"calculateFolderSizes": true}' > "$cfg/prefs.json"
		/bin/rm -f "$OUT/$name.png"
		env PATHEM_DEMO=1 PATHEM_CONFIG_DIR="$cfg" PATHEM_SITE_SHOT="$name" PATHEM_SITE_CAPTURE=screen \
			PATHEM_SITE_SIZE="$SIZE" PATHEM_SITE_OUT="$OUT/$name.png" "${extra[@]}" "$BIN" > "$OUT/$name.log" 2>&1 &
		pid=$!
		( /bin/sleep 60; kill $pid 2>/dev/null ) &
		watchdog=$!
		wait $pid
		kill $watchdog 2>/dev/null
		/bin/rm -rf "$cfg"
		[[ -s "$OUT/$name.png" ]] || continue
		# Active window: the close button is red. Inactive: all three lights are grey.
		red=$(/usr/bin/sips -g pixelWidth "$OUT/$name.png" >/dev/null 2>&1 && \
			/usr/bin/python3 - "$OUT/$name.png" <<'PY'
import os, subprocess, sys, tempfile
src = sys.argv[1]
bmp = os.path.join(tempfile.mkdtemp(), "shot.bmp")
subprocess.run(["/usr/bin/sips", "-s", "format", "bmp", src, "--out", bmp], capture_output=True)
data = open(bmp, "rb").read()
offset = int.from_bytes(data[10:14], "little")
width = int.from_bytes(data[18:22], "little")
height = int.from_bytes(data[22:26], "little", signed=True)
step = int.from_bytes(data[28:30], "little") // 8
stride = (width * step + 3) & ~3
corner = 120 if width > 2000 else 60
best = 0
for row in range(corner):
    y = row if height < 0 else abs(height) - 1 - row  # BMP rows run bottom-up unless height < 0
    base = offset + y * stride
    for x in range(corner):
        b, g, r = data[base + x * step], data[base + x * step + 1], data[base + x * step + 2]
        best = max(best, r - max(g, b))
os.remove(bmp)
print(1 if best > 60 else 0)
PY
)
		if [[ "$red" == 1 ]]; then ok=1; break; fi
		echo "$name: window was not active on attempt $attempt, retrying"
	done
	if [[ $ok == 1 ]]; then echo "ok    $name  $OUT/$name.png"; else echo "FAIL  $name"; failed=1; fi
done
exit $failed
