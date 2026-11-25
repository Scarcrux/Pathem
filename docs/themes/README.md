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
(`.json` or `.jsonc`, comments allowed) or an iTerm2 `.itermcolors` file.

- VS Code applies supported opaque background and accent colors to Pathem's window.
  Light and dark declarations map to the corresponding appearance.
- iTerm2 applies the imported foreground, background, cursor, and complete 16-color
  ANSI palette to the embedded terminal. Missing roles keep their current values.
  The import does not read shell or font settings.

The preview identifies the destination and shows a color swatch. Apply saves the palette.

## Complete looks

Pathem bundles 22 themes. Each supplies a palette, a folder style, a file icon set, and a toolbar glyph style. In **Settings → Appearance**, choose a skin to preview it. The three style pickers each offer ten choices plus **Use Theme**. **System** explicitly selects macOS folder or file icons, or Pathem’s standard toolbar glyphs. Choose **Use Theme** to clear that picker’s override. Changing the skin or resetting it keeps explicit style overrides, including file icon choices saved by earlier versions.

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

## Themes gallery

Every Pathem build includes the Themes gallery. Open **Settings → Appearance →
Themes…** to browse approved listings published by the project.

1. **Browse** lists the current approved revision of each listing. Search matches
   titles, creators, and tags. Each listing shows its creator, license, optional
   source, and one to three screenshots.
2. **Preview** shows the theme live and restores your previous look when you close it.
3. **Install** saves a copy on this Mac without changing your appearance. **Apply**
   switches to an installed theme.
4. When a listing publishes a higher revision, **Browse** offers **Update**. The
   installed copy stays as it is until you update, and the applied look changes only
   when you apply the new revision.
5. **Installed** lists your copies, including listings that were later withdrawn.
   **Uninstall** removes a copy. Uninstalling the applied theme restores System.

Pathem requests the catalog only when you open the gallery. It makes no catalog
request at launch or in the background. The request goes to the project's CloudFront
endpoint over HTTPS and carries no local files, file names, installed themes, or search
text. If the request or validation fails, Pathem shows the error, does not open the
gallery, and leaves the stored copy unchanged. An applied theme is saved in your
preferences and keeps working offline.
`test/themes_shipped_test.py` pins the single fetch entry point and its callers.

## Submit a theme

Open **Settings → Appearance → Submit a Theme…**. Choose one to three screenshots,
enter the listing details, and save the validated JSON. Pathem then offers to open
the **Submit a Pathem theme** GitHub issue form, where you attach the saved file.
Preparing a submission makes no network request from Pathem. The file and the issue
are public. [The example fixtures](gallery-fixture/) show the format.

Choose PNG or JPEG screenshots. Pathem re-encodes each one for the listing, keeping
only the pixels, so no metadata from your file is published. Published screenshots are
HEIC. Listings published earlier keep their PNG or JPEG screenshots, and the gallery
shows either.

A maintainer with write access reviews the submission, records the decision in a
private review store, and publishes the generated snapshot to the catalog host. The
app cannot record review decisions, and the public file carries no reviewer notes.
See [the review dashboard](admin-dashboard.md) for the review runbook and the publish
command.

## Catalog tool

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

## Local development

Release builds always read the published catalog and ignore the overrides below.
To point a debug build at another snapshot, launch it with
`PATHEM_COMMUNITY_GALLERY=1`, a scratch `PATHEM_CONFIG_DIR`, and
`PATHEM_SHARED_THEME_CATALOG` set to the HTTPS snapshot URL. HTTP is accepted only on
`127.0.0.1`. Opening the gallery fetches and validates the snapshot before replacing
discovery results. Without the snapshot URL, the same flags open an isolated local
gallery with submission and **Review** controls and no network access.

Run the two-client lifecycle check with
`python3 test/shared_theme_catalog_e2e.py .build/debug/pathem-theme-catalog`.
The packaged end-to-end run (`make e2e-app`) repeats it against the assembled app and
checks discovery, install, and apply through the real gallery on loopback.
