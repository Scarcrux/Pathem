# Pathem changelog

This is the in-app changelog. It is shown on demand from Help > Release Notes;
Pathem never forces it in front of you. Author new versions at the top,
newest-first, as `## <version> - <date>` followed by `-` bullet lines. This file
is bundled into the app and read by the Release Notes window.

## 0.9.0 - 2026-11-11
- Finder parity: the full set of Finder sort and group options, per-folder view options, in-place rename in every view, a Finder-style Dock menu with recent folders, spring-loaded path segments and navigation buttons during a drag, and Compress, Quick Look, Make Alias, Show Original and Show Package Contents in the right-click menu.
- Search: one search window for filenames or file contents, with This Folder, This Mac and Other Folder scopes. Replace in files now only ever changes files inside the folder you chose.
- Always Open With works for files with no extension, such as .env and Makefile, and opens the file as soon as you set it.
- PDF and image viewing in a pane, with Preview-style markup. Unsaved markup is kept if a save fails, instead of being lost when you navigate away.
- Photos library browsing and export, Remove Background, Auto-Tag by Content, a near-duplicate photo culler, a crop editor, and audio and video conversion.
- A bulk metadata editor (EXIF, IPTC, Finder tags and comments), Remove Location, batch-rename presets with date, parent-folder and EXIF tokens, and a grouped duplicate resolver.
- Customizable pane header: show, hide and reorder its buttons. Tabs can be reordered, moved between panes and torn off into a window.
- Reveal in Pathem for VS Code and Cursor, alongside the existing editor integrations. Jupyter notebooks preview safely inside Pathem.
- Live Quick Look previews in the column and gallery views.
- A visible update button in the window title bar when a new version is ready, and this Release Notes window.
- Confirmation popovers no longer cancel themselves when one follows another quickly, and closing a tab can no longer close a tab you are not looking at.
- All six languages are fully translated.

## 0.8.0 - 2026-07-20
- Native Swift BitTorrent engine with an optional confirm for inbound magnet and torrent links and a configurable download folder.
- Reveal in Pathem integrations for JetBrains IDEs, Sublime Text, and TextMate, plus a one-click `pathem` command-line tool.
- Per-folder saved views and layouts, an embedded themeable terminal, and a command palette with an on-device AI bar.
