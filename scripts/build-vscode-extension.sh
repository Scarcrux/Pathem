#!/usr/bin/env bash
# Package the "Reveal in Pathem" VS Code / Cursor extension into a .vsix and drop a
# copy into the app's resource bundle, where VSCodeIntegration installs it from.
#
# Run this whenever Integrations/vscode-pathem changes, then bump VSCodeIntegration
# .vsixName (and the resource filename) if the version changed. Requires node/npx.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT_DIR="$ROOT/Integrations/vscode-pathem"
RES_DIR="$ROOT/Sources/Pathem/Resources"

version="$(node -e "process.stdout.write(require('$EXT_DIR/package.json').version)")"
name="$(node -e "process.stdout.write(require('$EXT_DIR/package.json').name)")"
vsix="$name-$version.vsix"

echo "==> Packaging $vsix"
( cd "$EXT_DIR" && node --check extension.js && npx --yes @vscode/vsce package --allow-missing-repository )

echo "==> Copying into app resources"
# Remove any stale versioned copies so only the current one ships.
rm -f "$RES_DIR"/"$name"-*.vsix
cp "$EXT_DIR/$vsix" "$RES_DIR/$vsix"

echo "==> Done: $RES_DIR/$vsix"
echo "    If the version changed, set VSCodeIntegration.vsixName to \"$name-$version\"."
