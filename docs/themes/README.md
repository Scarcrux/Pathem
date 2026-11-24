# Themes 01 pilot

A v1 package is one UTF-8 JSON object up to 16 KiB. Include each of the five keys shown in [Orchard.json](Orchard.json). Use `1` for `schemaVersion`, a nonblank `name`, and `system`, `light`, or `dark` for `appearance`. Both color fields accept `#RRGGBB` or `null` for the corresponding system color. The importer rejects additional keys and unsupported versions before rendering a preview. Pathem stores the applied values through its existing preferences format.

In **Settings → Appearance**, pick **Harbor** under Skin to preview it, or choose **Import…** and open Orchard.json. **Apply** saves the preview. **Cancel** restores the previous look. Use **Appearance** and the two color controls to override individual values. Each color has a control for clearing it to its system default. **Export…** writes the current values with any overrides. **Reset Theme** restores System appearance and colors. Toolbar customization, file icons, and density have their own controls.

| Sample | Appearance | Accent | Background |
| --- | --- | --- | --- |
| System | System | System | System |
| Harbor | Dark | `#82D4DE` | `#182630` |
| Orchard | Light | `#2D694F` | `#F5F2E8` |

## Verification

The theme tests cover both samples, package rejection, export round-trips, independent overrides, and reset. The offscreen AppKit smoke check passed with a reordered toolbar through preview, cancel, apply, and reset. Run it from the repository with `PATHEM_SMOKE=themes PATHEM_DEMO=1` on the debug Pathem executable. The visual review and toolbar autosave across a full relaunch still need a desktop run.

## Checks before adding themes

1. Use System as the baseline. For each sample, check text legibility, active and inactive selection, keyboard focus, and separation of content, sidebar, and list header. Check standard AppKit controls with the system accent as well.
2. Customize the main toolbar by reordering two items and write down the ordered item identifiers. Compare the sequence during preview and after Cancel, Apply, Reset Theme, and a full quit and relaunch.
3. Change and clear appearance, accent, and tint individually. Check the other two values, file icon set, and density after each action. Export the result, reset, import the export, and verify that the preview and applied values match.
4. Import malformed JSON, a package with an extra key, and a package with a future version. Verify the current look and saved preferences after each rejection.

## Import colors from another app

Use **Settings → Appearance → Import…** and select an exported VS Code color theme
(`.json` or JSON with comments) or an iTerm2 `.itermcolors` file.

- VS Code applies supported opaque background and accent colors to Pathem's window.
  Light and dark declarations map to the corresponding appearance.
- iTerm2 applies the imported foreground, background, cursor, and complete 16-color
  ANSI palette to the embedded terminal. Missing roles keep their current values.
  The import does not read shell or font settings.

The preview identifies the destination and shows a color swatch. Apply saves the palette.
