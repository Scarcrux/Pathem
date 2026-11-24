# Pathem themes

A v1 package is one UTF-8 JSON object up to 16 KiB. Include each of the five keys shown in [Orchard.json](Orchard.json). Use `1` for `schemaVersion`, a nonblank `name`, and `system`, `light`, or `dark` for `appearance`. Both color fields accept `#RRGGBB` or `null` for the corresponding system color. The importer rejects additional keys and unsupported versions before rendering a preview. Pathem stores the applied values through its existing preferences format.

In **Settings → Appearance**, pick **Harbor** under Skin to preview it, or choose **Import…** and open Orchard.json. **Apply** saves the preview. **Cancel** restores the previous look. Use **Appearance** and the two color controls to override individual values. Each color has a control for clearing it to its system default. **Export…** writes the current values with any overrides. **Reset Theme** restores System appearance and colors. Toolbar customization, file icons, and density have their own controls.

| Sample | Appearance | Accent | Background |
| --- | --- | --- | --- |
| System | System | System | System |
| Harbor | Dark | `#82D4DE` | `#182630` |
| Orchard | Light | `#2D694F` | `#F5F2E8` |

## Import colors from another app

Use **Settings → Appearance → Import…** and select an exported VS Code color theme
(`.json` or JSON with comments) or an iTerm2 `.itermcolors` file.

- VS Code applies supported opaque background and accent colors to Pathem's window.
  Light and dark declarations map to the corresponding appearance.
- iTerm2 applies the imported foreground, background, cursor, and complete 16-color
  ANSI palette to the embedded terminal. Missing roles keep their current values.
  The import does not read shell or font settings.

The preview identifies the destination and shows a color swatch. Apply saves the palette.

## Complete looks

Pathem bundles 23 themes. Each supplies a palette, a folder style, a file icon set, and a toolbar glyph style. In **Settings → Appearance**, choose a skin to preview it. The three style pickers each offer ten choices plus **Use Theme**. **System** explicitly selects macOS folder or file icons, or Pathem’s standard toolbar glyphs. Choose **Use Theme** to clear that picker’s override. Changing the skin or resetting it keeps explicit style overrides, including file icon choices saved by earlier versions.

Export now writes a v2 package. It uses the v1 palette fields and requires three additional string fields. For example, Harbor ships these values.

```json
{
  "schemaVersion": 2,
  "name": "Harbor",
  "appearance": "dark",
  "accent": "#82D4DE",
  "background": "#182630",
  "folderStyle": "Azure",
  "fileIconSet": "Blueprint",
  "toolbarStyle": "Rounded"
}
```

Exports capture the effective styles, including any active overrides. On import, those values become the theme’s bundled styles. Select **Use Theme** in all three pickers to see an imported package without local style overrides. V1 and VS Code imports update the palette and keep the current styles. iTerm2 imports still update the terminal palette.

See [catalog verification](catalog-verification.md) for the commands and coverage.

## Embedded icon artwork

A version 3 theme adds an `artwork` object to the version 2 fields. Its `files`
and `toolbar` objects map icon roles to base64-encoded PNGs. Use file roles such as
`folder`, `document`, or `image`, and toolbar symbol names such as
`magnifyingglass`. Unspecified icons use the theme's selected styles. A user can
override the folder, file, and toolbar styles independently. Up to 16 single-frame PNGs
are allowed, each at most 256 pixels per side and 16 KiB. The package has no external
asset paths. Export carries the embedded artwork and System reset clears it.

## Shared catalog staging

Creators prepare a submission using [the example fixtures](gallery-fixture/) and open
the **Submit a Pathem theme** GitHub issue form. A maintainer with write access reviews
the submission, records the decision in a private review store, and publishes the
generated snapshot to the catalog host. Use branch protection to restrict who can
update the published snapshot. The publisher does not accept review decisions from
the app or include reviewer notes in the public file.

Build the publisher with `swift build --build-system native --product pathem-theme-catalog`.
On the maintainer's machine, with the review store in a private directory, run:

```sh
pathem-theme-catalog /path/to/private/reviews.json submit submission.json
pathem-theme-catalog /path/to/private/reviews.json review theme-id 1 approved Reviewer "Reviewed"
pathem-theme-catalog /path/to/private/reviews.json snapshot /path/to/hosted/catalog.json
```

Use a higher version to submit an update. To withdraw a listing, run
`pathem-theme-catalog /path/to/private/reviews.json withdraw theme-id` and publish a new
snapshot. Clients keep their installed copies after withdrawal and can still uninstall them.

For a local shared-gallery preview, launch a debug build with
`PATHEM_COMMUNITY_GALLERY=1`, a scratch `PATHEM_CONFIG_DIR`, and
`PATHEM_SHARED_THEME_CATALOG` set to the HTTPS snapshot URL. The preview also accepts
HTTP on `127.0.0.1` for local verification. Opening Community Themes fetches and
validates the snapshot before replacing discovery results. Without the shared URL, the
existing isolated local submission and review pilot is available.

Run the two-client staging check with
`python3 test/shared_theme_catalog_e2e.py .build/debug/pathem-theme-catalog`.
