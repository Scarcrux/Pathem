# Themes 03 catalog verification

Run on the assigned checkout on macOS 27.2.1 (26B131). The built-in catalog contains 23 complete looks and ten choices each for folders, file icons, and toolbar glyphs. Each picker also has **Use Theme**.

| Check | Result |
| --- | --- |
| Themes 01 gate | The unchanged pilot at `a7d6611` built and passed the offscreen reordered-toolbar smoke. A desktop visual pass on the pilot was unavailable in this runner. |
| Focused Swift tests | 12 tests passed. Coverage includes all built-in v2 round trips, v1 Orchard, VS Code and iTerm2 imports, invalid packages, saved legacy file icon choices, independent override clearing, and reset. |
| Full Swift suite | The run reported failures in OrganizePlanner tests and exited with status 70 without a suite summary. See `.build/catalog-full-tests.log`. |
| Catalog AppKit smoke | Passed. Preview, cancel, apply, reset, and changing and clearing each style override preserved the customized toolbar order within the same process. The check exercised the browser’s appearance path programmatically. |
| Catalog and style renders | Reviewed 23 List renders, ten Icon renders covering every style choice, and the 20-view matrix below. The seeded PNGs showed file glyph and Quick Look fallback behavior. The demo’s red tag dot remained visible. |
| Native toolbar autosave across relaunch | Write probe passed in-process. The read probe failed after a full process restart. The first process had a native saved item order and reported successful defaults synchronization. The order was absent before installing the toolbar in the second process. The actual desktop quit and relaunch remains unverified. |

## View matrix

Each cell was reviewed in an offscreen AppKit capture. The contrast columns use AppKit’s increased-contrast appearances directly.

| View | Paper Light | Paper Light increased contrast | Harbor Dark | Harbor Dark increased contrast |
| --- | --- | --- | --- | --- |
| List | Reviewed | Reviewed | Reviewed | Reviewed |
| Icon | Reviewed | Reviewed | Reviewed | Reviewed |
| Gallery | Reviewed | Reviewed | Reviewed | Reviewed |
| Column | Reviewed | Reviewed | Reviewed | Reviewed |
| Tree | Reviewed | Reviewed | Reviewed | Reviewed |

The initial Icon and Gallery renders exposed a legibility issue when a selected Accent folder used the same color as the selection fill. The rerenders show the folder and filename with a translucent fill and accent outline. In the inactive offscreen window, native toolbar glyphs are dimmer than the pane controls. The renders covered toolbar shapes and placement. Active-window toolbar contrast, keyboard focus during interaction, thumbnail generation, and live Quick Look still require a desktop check. The PNG fixtures displayed fallback icons in the runner. The native Increase Contrast toggle and the Settings file dialogs were also outside the offscreen coverage.

## Commands run

The runner’s default SwiftPM build failed at SwiftTerm’s Metal shader compilation. The native build system succeeded using the Xcode toolchain directly and dependency caches copied into the isolated checkout. All Swift operations used the shared lock.

```sh
export TMPDIR="$PWD/.build/local-tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/local-cache"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
toolchain="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"

lockf -k /tmp/commandem-swift-build.lock "$toolchain/swift" build   --build-system native --disable-sandbox --skip-update --cache-path "$CLANG_MODULE_CACHE_PATH"
lockf -k /tmp/commandem-swift-build.lock "$toolchain/swift" test   --build-system native --disable-sandbox --skip-update --cache-path "$CLANG_MODULE_CACHE_PATH"   --filter Theme
lockf -k /tmp/commandem-swift-build.lock "$toolchain/swift" test \
  --build-system native --disable-sandbox --skip-update --cache-path "$CLANG_MODULE_CACHE_PATH"
PATHEM_SMOKE=themes PATHEM_DEMO=1 .build/debug/Pathem

mkdir -p .build/catalog-config .build/theme-shots
PATHEM_DEMO=1 PATHEM_CONFIG_DIR="$PWD/.build/catalog-config"   PATHEM_THEME_SHOTS="$PWD/.build/theme-shots" .build/debug/Pathem

catalogRunID=$(uuidgen)
for pass in write read; do
  PATHEM_DEMO=1 PATHEM_CONFIG_DIR="$PWD/.build/catalog-config"     PATHEM_THEME_AUTOSAVE_TEST="$pass" PATHEM_THEME_AUTOSAVE_ID="$catalogRunID" .build/debug/Pathem
done
```

A second visual run supplied a fresh `PATHEM_DEMO_ROOT` and added three synthetic PNGs to its `Photos/2026-11 Lisbon` folder before capture. The 53 local captures from that run are in `.build/theme-shots-reviewed/`. The focused test, smoke, and relaunch logs are `.build/catalog-tests.log`, `.build/catalog-smoke.log`, and `.build/catalog-autosave-final.log`. The captures and logs are local to the assigned checkout.
