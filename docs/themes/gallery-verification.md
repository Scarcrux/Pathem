# Themes 04 gallery verification

This is the verification record for the local gallery pilot. The gallery now ships in every build and reads the published catalog; see [the Themes guide](README.md#themes-gallery). The local review flow recorded here remains available in debug builds.

The built-in catalog at `0b7cfda` was present before implementation. Verification ran on macOS 27.2.1 (26B131) in the assigned checkout. The gallery is available in debug builds with `PATHEM_COMMUNITY_GALLERY=1` and an explicit `PATHEM_CONFIG_DIR`. Submissions, reviews, withdrawals, and installed copies are stored in that local configuration directory.

## Local review

The staged catalog contains one approved listing, **Tidal Marsh v1**, by **Pathem contributors** under **CC0-1.0**. It starts with no theme installed. Launch the app from the checkout, then open **Settings → Appearance → Themes…**.

```sh
TMPDIR="$PWD/.build/local-tmp" PATHEM_COMMUNITY_GALLERY=1 \
  PATHEM_CONFIG_DIR="$PWD/.build/local-tmp/gallery-review" PATHEM_DEMO=1 \
  .build/debug/Pathem
```

The checked-in [fixture](gallery-fixture/) includes both submission JSON files, their original Pathem packages, and the ordered v1 and v2 decisions in `reviews.json`. Each submission embeds two screenshots of the theme in Pathem's demo workspace. To exercise the update in the staged gallery, install and apply v1, submit `v2.submission.json`, then record its approval in **Review**. Check that **Browse** offers **Update**, that **Installed** still shows v1 before updating, and that the current appearance changes only after applying v2. **Review** also offers withdrawal, and **Installed** offers uninstall. For a full manual replay beginning with submission of v1, run the same launch command with a fresh configuration directory.

Creators can use the two submission files as examples. A submission contains a stable lowercase ID, positive integer revision, title, summary, creator, license, optional source attribution, tags, a base64-encoded Pathem theme package, and one to three base64-encoded PNG or JPEG screenshots. Source screenshots are limited to 2 MiB and 2400 pixels per side. Export and review intake re-encode previews as HEIC with a 300 KiB limit per image, keeping pixels only. A Mac that cannot encode HEIC falls back to PNG, then JPEG. Listings published earlier keep their PNG or JPEG screenshots, and the catalog accepts all three formats. Revisions of an existing listing use its ID and a higher version number.

## Results

| Check | Observed result |
| --- | --- |
| Native debug build | Passed with the Xcode toolchain under the shared Swift build lock. |
| Theme-focused tests | 15 tests passed, including rejection, invalid metadata and package, screenshot validation, and preservation of persisted state after a failed transaction. |
| Full static/unit verification | Batch A rerun passed 15 XCTest cases and 890 Swift Testing cases (180 suites). The earlier exit 70 did not reproduce. |
| Submission and approval | The AppKit smoke submitted v1 through the gallery controller. It confirmed the revision was pending and absent from Browse, then recorded the fixture approval. Search matched title, creator, and tags in one query, and a nonmatching query returned an empty list. |
| Details and preview | Creator, license, source, and both screenshot selections appeared in the gallery controls. The offscreen detail capture was inspected. The preview applied live tint and restored System appearance on exit, with the catalog still uninstalled. |
| Explicit install and apply | Install saved v1 and left System appearance active. Apply selected v1. A second process restored the installed revision and its applied appearance from disk. |
| Update | Pending v2 left approved v1 discoverable. After v2 approval, Browse offered Update and Installed retained v1. Update saved v2 while v1 remained applied. A separate Apply switched the live appearance to v2. |
| Withdrawal and uninstall | Withdrawal hid the listing and kept v2 manageable in Installed. Uninstall of the applied copy restored System. A third process confirmed the withdrawal and uninstall persisted. |
| Toolbar and overrides | The smoke verified that a customized toolbar order and independent folder, file icon, and toolbar overrides survived preview, restore, apply, update, and uninstall within the running process. The harness reapplies the custom order on each launch. |
| Built-in catalog regression | The existing Themes smoke passed and preserved customized toolbar order. |

The AppKit smoke drives the gallery controller and renders views offscreen. The native Open panel, alert buttons, keyboard navigation, active-window toolbar contrast, actual desktop quit and relaunch with native toolbar autosave, and the macOS Increase Contrast toggle still need a desktop pass. The smoke uses separate processes to verify the gallery store and application preferences independently of native toolbar autosave.

## View matrix

Inspected the themed browser in each view with the matching AppKit appearance. v1 is the light revision and v2 is the dark revision.

| View | v1 light | v1 increased contrast | v2 dark | v2 increased contrast |
| --- | --- | --- | --- | --- |
| List | Reviewed | Reviewed | Reviewed | Reviewed |
| Icon | Reviewed | Reviewed | Reviewed | Reviewed |
| Gallery | Reviewed | Reviewed | Reviewed | Reviewed |
| Column | Reviewed | Reviewed | Reviewed | Reviewed |
| Tree | Reviewed | Reviewed | Reviewed | Reviewed |

The first dark captures showed blue quick-action glyphs against the dark palette. The rerenders show that the quick-action bar updates tint with the theme. Gallery, Column, and Icon renders exercised demo file icons and preview fallbacks. The inactive offscreen toolbar remains dim. Captures and logs are under `.build/gallery-renders/` and `.build/gallery-*.log`.

## Commands run

The existing SwiftPM dependency checkouts, repositories, artifacts, and workspace state were copied into the checkout's `.build` directory before the locked native build. These commands show the effective invocations.

The commit hook's default `swift test` invocation failed when Xcode tried to write its cache outside the checkout. The direct locked test commands below supplied writable cache and temporary directories. The commit skipped the duplicate Swift test hook after those runs.

```sh
mkdir -p .build/local-tmp .build/local-cache
export TMPDIR="$PWD/.build/local-tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/local-cache"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
toolchain="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin"

lockf -k /tmp/commandem-swift-build.lock "$toolchain/swift" build \
  --build-system native --disable-sandbox --skip-update --cache-path "$CLANG_MODULE_CACHE_PATH"
lockf -k /tmp/commandem-swift-build.lock "$toolchain/swift" test \
  --build-system native --disable-sandbox --skip-update --cache-path "$CLANG_MODULE_CACHE_PATH" \
  --filter Theme
lockf -k /tmp/commandem-swift-build.lock "$toolchain/swift" test \
  --build-system native --disable-sandbox --skip-update --cache-path "$CLANG_MODULE_CACHE_PATH"
PATHEM_SMOKE=themes PATHEM_DEMO=1 PATHEM_CONFIG_DIR="$TMPDIR/gallery-catalog-regression" \
  .build/debug/Pathem > .build/gallery-catalog-smoke.log 2>&1

export PATHEM_COMMUNITY_GALLERY=1 PATHEM_DEMO=1
export PATHEM_COMMUNITY_FIXTURE="$PWD/docs/themes/gallery-fixture"
export PATHEM_CONFIG_DIR="$TMPDIR/gallery-e2e-$(uuidgen)"
mkdir -p "$PATHEM_CONFIG_DIR"
for phase in submit update relaunch; do
  PATHEM_COMMUNITY_GALLERY_TEST="$phase" .build/debug/Pathem \
    > ".build/gallery-e2e-$phase.log" 2>&1 || break
done

mkdir -p "$TMPDIR/gallery-review"
PATHEM_CONFIG_DIR="$TMPDIR/gallery-review" PATHEM_COMMUNITY_GALLERY_TEST=stage \
  .build/debug/Pathem > .build/gallery-stage.log 2>&1
```

The three-process run also generated `gallery-detail.png` in the isolated `gallery-e2e-…` configuration directory. For the view matrix, the app rendered each revision with four appearance variants. Three synthetic gradient PNGs were copied into the isolated demo's Lisbon folder before capture. The fixture JPEGs use the List and Icon captures cropped above the status bar.

```sh
mkdir -p .build/gallery-renders/{v1,v2} .build/gallery-render-seed
for palette in teal navy gold; do
  magick -size 600x380 "gradient:$palette-white" ".build/gallery-render-seed/$palette.png"
done
for version in v1 v2; do
  demo="${TMPDIR#/private}/gallery-demo-$(uuidgen)"
  PATHEM_DEMO_ROOT="$demo" PATHEM_CONFIG_DIR="$PWD/.build/gallery-render-config" PATHEM_DEMO=1 \
    PATHEM_COMMUNITY_RENDER_PACKAGE="$PWD/docs/themes/gallery-fixture/$version.theme.json" \
    PATHEM_THEME_SHOTS="$PWD/.build/gallery-renders/$version" \
    .build/debug/Pathem > ".build/gallery-render-$version.log" 2>&1 &
  render_pid=$!
  for attempt in $(seq 1 200); do
    if [ -d "$demo/Photos/2026-11 Lisbon" ]; then
      cp .build/gallery-render-seed/*.png "$demo/Photos/2026-11 Lisbon/"
      break
    fi
    sleep 0.02
  done
  wait "$render_pid" || break
done
```
