# Pathom

A fast, native macOS file manager. Dual-pane, keyboard-driven, and built to stay
quick even in folders with a lot of files.

It's a Finder alternative for people who want more control, in the spirit of
Directory Opus or Path Finder. Written in Swift and AppKit. No Electron.

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange)

<!-- TODO: a short demo GIF (a big folder scrolling, plus a semantic search). -->

## What it does

- Two panes side by side, with copy and move between them (F5 and F6).
- Stays fast in large folders. Only the rows on screen are built, so 100k or even
  a million files scroll without lag.
- Quick navigation: an editable path bar, back, forward, up, and double-click or
  Return to open a folder.
- Sortable columns (name, size, date modified), folders first.
- On-device semantic search. Type what you're after in plain language and Pathom
  ranks the folder by meaning, using Apple's NaturalLanguage embeddings over file
  names and the text inside files (including PDFs). It runs entirely on your Mac,
  costs nothing, and doesn't need Apple Intelligence. (OCR for images is built in
  but off by default for now.)
- Copy and move never overwrite silently. If a name already exists, that item is
  skipped and reported.

## Why it's fast

Two things do most of the work. To read a folder, Pathom uses getattrlistbulk,
which returns many entries and their attributes in one system call instead of a
readdir plus a stat for every file. To draw the list, it uses a view-based
NSTableView with cell reuse, so only the visible rows are ever created.

Rough numbers on an Apple Silicon Mac, loading a synthetic folder of a million
entries:

```
1,000,000 entries
reload + first layout:                  ~47 ms
cell views built for the first screen:  ~93   (about the visible rows x 3 columns)
cell views built per scroll jump:       ~100
```

Jumping to the last row costs about the same as jumping to the tenth.

## Building

Requires macOS 15 or later and a recent Swift toolchain.

```
make run       # build and launch from source (fastest loop)
make build     # build the engine and the app
make test      # run the engine tests
make app       # assemble .build/Pathom.app (universal, ad-hoc signed)
make install   # build the app and copy it to /Applications
```

(These wrap plain `swift build` / `swift run Pathom` / `swift test` if you
prefer to call those directly.)

### Packaging a .app

`make app` (or `scripts/package.sh`) assembles a universal (Apple Silicon +
Intel), ad-hoc signed `Pathom.app` under `.build/`. `make install` also copies
it to /Applications.

```
make app                           # local, ad-hoc signed, double-clickable
ARCHS="arm64" scripts/package.sh   # faster, native only
```

For a distributable build, set `DEVELOPER_ID` to a "Developer ID Application"
identity (signs with Hardened Runtime) and `NOTARY_PROFILE` to a stored
`notarytool` profile to also notarize and staple. See the comments at the top of
the script.

This bundle is the prerequisite for the App Intents and Services surfaces. Full
Shortcuts discovery of the semantic-search action also needs the App Intents
metadata-extraction step, which the Xcode build system runs but a plain `swift
build` does not yet; the intent code and the bundle are in place. The command
bar's on-device LLM additionally needs macOS 26 with Apple Intelligence and
falls back to a heuristic everywhere else.

## Status

Early, but already useful: a fast dual-pane file manager with on-device semantic
search. It doesn't cover everything a tool like ForkLift does yet. DESIGN.md has
the plan, including tabs, saved layouts, batch rename, richer search across PDFs
and images, and a file-system watcher that keeps the view in sync with the disk.

## License

MIT, see [LICENSE](LICENSE). "Pathom" is the project name, so please don't ship a
fork under it.

Built by [Scarcrux](https://github.com/Scarcrux). If Pathom is useful to you, a
star helps, and you can find my other work on
[my profile](https://github.com/Scarcrux?tab=repositories).
