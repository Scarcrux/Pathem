# Pathem changelog

This is the in-app changelog. It is shown on demand from Help > Release Notes;
Pathem never forces it in front of you. Author new versions at the top,
newest-first, as `## <version> - <date>` followed by `-` bullet lines. This file
is bundled into the app and read by the Release Notes window.

## 0.9.2 - 2026-11-18
- Settings, Updates has a new switch, Automatically download and install updates. It is off by default, so Pathem still asks before installing an update.

## 0.9.1 - 2026-11-18
- Fixed a crash when opening the Size Browser on a folder with contents.
- The Photos browser opens again after you close it.
- File names under the Gallery preview and in the Column view's preview stay visible in short panes, for example with both the terminal and torrent drawers open.
- The "no such path" suggestions sheet now fits the window: long paths are shortened in the middle, and the full path is still available.
- About now names Scarcrux LLC as the copyright holder.

## 0.9.0 - 2026-11-17
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
- Themes: 22 built-in themes, grouped Light and Dark with a swatch for each, and a theme now tints the whole window, title bar, column headers and sidebar included. The terminal's System theme follows it.
- Find in Files and semantic search say what they are doing: indexing and ranking states, a failed search with its reason, and when a result cap was reached. Semantic search is also a mode of the Cmd-F search window.
- macOS Services in the file context menu, and Download Now and Remove Download for iCloud files.
- Torrents: magnet links use their web seeds and .torrent sources, a magnet still looking for its file list says so, and the progress bars in the Torrents drawer and window are visible again.
- The Network view now shows its own name in the tab and window title.
- Folder size calculation skips cache and temporary folders by default (configurable), stops when you leave the folder, and uses fewer threads at once.
- Closing a window, quitting or leaving a PDF with unsaved markup asks to save, with an option to save automatically instead. In a name conflict, Return keeps both files.
- The Photos browser can now ask for access to your library; before, macOS refused it without asking. About shows the build's source commit and the open-source licenses Pathem includes.
- Fixed a crash on some Japanese and Chinese alerts.
- Leaving an edited archive now offers Cancel as well as Save and Discard: Cancel keeps your edits unsaved, and reopening the archive picks them up again.
- Pathem now has 12 interface languages. English is the source; the other 11 (French, German, Spanish, Japanese, Simplified and Traditional Chinese, Italian, Brazilian Portuguese, Korean, Russian, Dutch) are AI-drafted and have not been reviewed by native speakers.

## 0.8.0 - 2026-07-20
- Native Swift BitTorrent engine with an optional confirm for inbound magnet and torrent links and a configurable download folder.
- Reveal in Pathem integrations for JetBrains IDEs, Sublime Text, and TextMate, plus a one-click `pathem` command-line tool.
- Per-folder saved views and layouts, an embedded themeable terminal, and a command palette with an on-device AI bar.
