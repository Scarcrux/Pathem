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
