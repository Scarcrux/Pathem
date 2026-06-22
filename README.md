# Pathem

A fast, native macOS file manager. Dual-pane, keyboard-driven, and built to stay
quick even in folders with a lot of files.

It's a Finder alternative for people who want more control, in the spirit of
Directory Opus or Path Finder. Written in Swift and AppKit. No Electron.

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange)

<!-- TODO: a short demo GIF (a big folder scrolling, plus a semantic search). -->

## What it does

- Two panes side by side, with tabs per pane, and copy and move between them
  (F5 and F6).
- Stays fast in large folders. Only the rows on screen are built, so 100k or even
  a million files scroll without lag.
- Drag and drop: drag files between panes, to and from Finder, or onto the
  sidebar. Copy by default, hold Command to move.
- A customizable sidebar. Reorder shortcuts by drag, rename them, change their
  icons, and organize them into your own groups. Cloud services and mounted
  volumes show up automatically below your groups.
- An embedded terminal that follows the active folder (Ctrl-`). It runs a real
  login shell (vim, ssh, REPLs, colors) and is themeable: pick System, Dracula,
  Nord, or Solarized, or set your own font, colors, and shell.
- On-device semantic search. Type what you're after in plain language and Pathem
  ranks the folder by meaning, using Apple's NaturalLanguage embeddings over file
  names and the text inside files (including PDFs). It runs entirely on your Mac,
  costs nothing, and doesn't need Apple Intelligence. (OCR for images is built in
  but off by default for now.)
- A command palette and an on-device AI command bar, both bound to a rebindable
  command registry and keymap.
- Per-folder saved views, saved layouts, Quick Look (Space), and batch rename.
- Quick navigation: an editable path bar, back, forward, up, and double-click or
  Return to open a folder. Sortable columns (name, size, date modified), folders
  first.
- Cloud-aware. It browses iCloud, Dropbox, Drive, and OneDrive folders and never
  silently downloads online-only files just to list or index them.
- Copy and move never overwrite silently. If a name already exists, that item is
  skipped and reported.

## Why it's fast

Two things do most of the work. To read a folder, Pathem uses getattrlistbulk,
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

## Install

### Download (notarized)

Grab the latest `Pathem-vX.Y.Z-universal.zip` from
[Releases](https://github.com/Scarcrux/Pathem/releases): a universal (Apple
Silicon + Intel), Developer ID-signed, notarized, stapled build. Unzip and drag
`Pathem.app` to /Applications. No Gatekeeper warnings, no build step. Releases
are produced automatically by the `Release` workflow when a `v*` tag is pushed.

### Build from source

Building it yourself needs no Apple Developer account: a locally compiled app is
not quarantined, so it launches with no Gatekeeper prompts. You need macOS 15 or
later and the Swift toolchain (Xcode, or just the Command Line Tools via
`xcode-select --install`).

```
git clone https://github.com/Scarcrux/Pathem.git
cd Pathem
make install     # build a universal Pathem.app and put it in /Applications
# or
make run         # build and launch straight from source
```

Signing and notarization only matter if you hand someone a prebuilt download;
they are not needed to build and run it yourself.

## Building

```
make run            # build and launch from source (fastest loop)
make build          # build the engine and the app
make test           # run the engine tests
make smoke          # launch and assert the window/pane layout invariants
make app            # assemble .build/Pathem.app (host arch, ad-hoc signed)
make install        # build the app and copy it to /Applications
make watch          # rebuild and relaunch on every save (fast debug loop)
make watch-install  # same, but reinstall the signed app each save
make dev-cert       # create a stable self-signed identity so a Full Disk Access
                    # grant survives rebuilds (then SIGN_IDENTITY=... make install)
```

(These wrap plain `swift build` / `swift run Pathem` / `swift test` if you
prefer to call those directly.) `make watch` is the quickest way to iterate:
edit a file, save, and Pathem rebuilds and relaunches itself.

### Packaging a .app

`make app` (or `scripts/package.sh`) assembles an ad-hoc signed `Pathem.app`
under `.build/`. Local builds default to your Mac's architecture (fast);
distribution builds (`DEVELOPER_ID` set) go universal. The script builds each
architecture separately and joins them with `lipo`, which sidesteps the Metal
toolchain that a single multi-arch SwiftPM build would otherwise require for
SwiftTerm's shader. `make install` also copies the app to /Applications.

```
make app                                 # local, host arch, ad-hoc signed
ARCHS="arm64 x86_64" scripts/package.sh  # universal, no Metal toolchain needed
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

## Full Disk Access

Pathem is non-sandboxed, so your home folder works out of the box. To browse
everything (other users, system folders, some app data), grant it Full Disk
Access: **System Settings ▸ Privacy & Security ▸ Full Disk Access**, then add
Pathem. The app shows a one-time prompt with a shortcut to that pane on first
launch. Without it, an unreadable folder is shown as "Pathem may need Full Disk
Access" rather than a blank pane.

## Status

Already useful day to day: a fast dual-pane file manager with tabs per pane, a
fully customizable sidebar, drag and drop, an embedded themeable terminal,
per-folder saved views, saved layouts, Quick Look, batch rename, a command
palette, on-device semantic search, and a watcher that keeps the view in sync
with the disk. Remote/cloud transfer (S3, WebDAV, SFTP) is the planned
fast-follow. DESIGN.md and ROADMAP.md have the full plan.

## License

MIT, see [LICENSE](LICENSE). "Pathem" is the project name, so please don't ship a
fork under it.

Built by [Scarcrux](https://github.com/Scarcrux). If Pathem is useful to you, a
star helps, and you can find my other work on
[my profile](https://github.com/Scarcrux?tab=repositories).
