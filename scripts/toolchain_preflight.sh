#!/usr/bin/env bash

set -euo pipefail

selected="$(command -v swift 2>/dev/null || true)"
xcode_swift="$(xcrun --toolchain XcodeDefault --find swift 2>/dev/null || true)"

if [[ -z "$selected" ]]; then
  echo "error: Swift is not installed or not on PATH" >&2
  exit 1
fi
if [[ -z "$xcode_swift" ]]; then
  echo "error: Xcode's default Swift toolchain is unavailable; run xcode-select --install or select Xcode" >&2
  exit 1
fi

selected_version="$(swift --version 2>&1 | head -1)"
xcode_version="$(xcrun --toolchain XcodeDefault swift --version 2>&1 | head -1)"
if [[ "$selected_version" != "$xcode_version" ]]; then
  echo "error: PATH selects a Swift toolchain that does not match the active Xcode SDK" >&2
  echo "  selected: $selected ($selected_version)" >&2
  echo "  Xcode:    $xcode_swift ($xcode_version)" >&2
  echo "Run through make (which selects Xcode Swift), or prepend $(dirname "$xcode_swift") to PATH." >&2
  exit 1
fi

echo "ok   toolchain: $selected_version"
echo "ok   build system: SwiftPM native (single-architecture shader copy; avoids Xcode 27 swiftbuild Metal regression)"
