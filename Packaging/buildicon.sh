#!/usr/bin/env bash
# Render Pathem's app icon and assemble Packaging/Pathem.icns.
# Style arg (default "aqua" = the path/river hybrid): aqua | river | route.
set -euo pipefail
cd "$(dirname "$0")/.."

style="${1:-aqua}"
swift Packaging/makeicon.swift Packaging/AppIcon-1024.png "$style"

iconset=Packaging/AppIcon.iconset
rm -rf "$iconset"; mkdir -p "$iconset"
for s in 16 32 128 256 512; do
  d=$((s * 2))
  sips -z "$s" "$s" Packaging/AppIcon-1024.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
  sips -z "$d" "$d" Packaging/AppIcon-1024.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Packaging/Pathem.icns
rm -rf "$iconset"
echo "wrote Packaging/Pathem.icns ($style)"
