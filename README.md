# Pathom

**A fast, native macOS file manager. No Electron. Handles 1M+ files instantly.**

A power-user Finder alternative (in the spirit of Directory Opus / Path Finder),
built in Swift + AppKit. Dual-pane, keyboard-driven, and engineered so that even
a million-file directory scrolls without a stutter.

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange)

<!-- TODO: hero GIF — a 1,000,000-row folder scrolling/filtering instantly, above the fold. -->

## Features

- **Dual-pane browsing** with one-key copy/move (F5 / F6) between panes.
- **Instant large directories** — view-based `NSTableView` with real cell
  recycling renders 100k+ (tested to 1,000,000) rows at native speed.
- **Fast navigation** — editable path bar, back / forward / up
  (Cmd-[ / Cmd-] / Cmd-Up), double-click or Return to descend.
- **Sortable columns** (name, size, date) with directories first.
- **Safe file ops** — copy/move refuse to overwrite and report failures
  (a full conflict-resolution policy + undo are on the roadmap).
- **On-device semantic search** — rank a folder by *meaning* using Apple's
  NaturalLanguage embeddings over file names **and text-file contents**: fully
  local, free, runs on every Mac (no cloud, no Apple Intelligence required), and
  cached per folder. Rich formats (PDF, Office, OCR) are next.

## How it works (the speed is the point)

- **Enumeration:** a `getattrlistbulk(2)` engine returns many entries *with their
  attributes* per syscall instead of `readdir` + a `stat` per file — it reads the
  full contents of `/usr/bin` (924 entries) in a single call. Entries are emitted
  as value-type structs into a contiguous array, sorted via an index vector.
- **Rendering:** a view-based `NSTableView` with a fixed row height and genuine
  cell recycling. Only the visible rows are ever materialized.

Measured on an M-series Mac (the project's "Gate A" proof):

```
1,000,000-row directory
reloadData + first layout: ~47 ms
cell views materialized for initial display: ~93   (≈ visible rows × 3 columns)
cells materialized per scroll jump (top / middle / last row): ~100
```

The table's cost is **O(visible)**, not O(rows) — scrolling to row 999,999 is as
cheap as scrolling to row 10.

## Build & run

Requires macOS 15+ and a recent Swift toolchain (Swift 6).

```bash
swift build            # build the engine + app
swift run Pathom       # launch the dual-pane browser on your home folder
swift test             # run the engine test suite
```

## Status

Early but real: a fast, native, dual-pane Finder alternative. It is **not yet**
at the feature breadth of ForkLift or Directory Opus — see
[DESIGN.md](DESIGN.md) for the architecture and the roadmap (tabs, saved
layouts, batch rename, and richer semantic search over PDFs and other formats).

## License

[MIT](LICENSE) © 2026 Scarcrux. "Pathom" is a project name; please don't ship a
fork under the same name.

---

Built by **[Scarcrux](https://github.com/Scarcrux)**. If Pathom is useful to
you, a ⭐ helps — and have a look at my
[other projects](https://github.com/Scarcrux?tab=repositories).
