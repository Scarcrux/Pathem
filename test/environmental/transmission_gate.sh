#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
XCODE_SWIFT="$(xcrun --toolchain XcodeDefault --find swift)"
if (cd "$ROOT" && "$XCODE_SWIFT" test --build-system native --filter ThirdPartyInteropTests); then
  echo "RESULT: PASS  Pathem downloaded and verified bytes from Transmission over loopback"
else
  echo "RESULT: FAIL  Transmission interoperability test failed"
  exit 1
fi
