# Pathem

A high-performance, deeply native macOS "superuser" file manager — a
Directory-Opus-class Finder replacement, built in Swift. See
**[DESIGN.md](DESIGN.md)** for the full design (competitive analysis,
architecture, MVP scope, risks) and **[CONVENTIONS.md](CONVENTIONS.md)** for
the shared constellation standards.

## At a glance
- **Language / UI:** Swift. AppKit (view-based `NSTableView` / `NSOutlineView`)
  for the high-performance file list; SwiftUI only for low-cardinality chrome.
- **Layout:** `PathemEngine` (pure Swift / Foundation, **zero AppKit
  dependency**, `swift test`-able) is separated from the `Pathem` app by a
  plain-struct boundary (no FFI). Engine = enumeration, watching, file ops,
  search.
- **Distribution:** non-sandboxed, notarized direct download, user-granted Full
  Disk Access, auto-update via **Sparkle** (EdDSA appcast). **Not** on the Mac
  App Store — the sandbox can't grant Full Disk Access.

## Build & test
```bash
swift build            # build engine + app
swift test             # run the engine test suite
swift run Pathem       # launch the (stub) app window
```

## Conventions (see CONVENTIONS.md)
- Stdlib-first; SwiftPM, no `.xcodeproj` unless the bundle / Sparkle /
  Liquid-Glass build genuinely needs it.
- `swift-format` + `swift test` on commit (pre-commit). Conventional Commits;
  authored as `Scarcrux` (GitHub noreply email — set before first commit).
- Tests prefer real I/O (temp dirs) over mocking.

## One-time setup (not yet run)
```bash
brew install swift-format                                   # not on PATH here
pre-commit install                                          # wire the hooks
polaris init . && polaris add . && polaris brief --apply    # constellation
```

## Current state
Well past scaffold; a working dual-pane manager. `PathemEngine` has the
`getattrlistbulk` `BulkEnumerator` (contract-tested against
`FoundationEnumerator`), plus file ops with undo, FSEvents watching, on-device
semantic search, git status, an out-of-process extension seam, and the remote
backends (S3, WebDAV, SFTP, FTP). The `Pathem` app has tabs per pane, a
customizable sidebar / toolbar / context menu, drag and drop (with file
promises, so drags land in browsers too), an embedded themeable terminal,
per-folder saved views + Layouts, a command palette + on-device AI bar over the
command registry, cleanup + an active organizer, remote transfers, and Sparkle
auto-update. See **DESIGN.md** ("Status (built)") and **ROADMAP.md** for detail;
Gate A (1M-row virtualization) is met.

## Next up
Track the living plan in **ROADMAP.md**. Candidate follow-ups: finish dissolving
the `BrowserViewController` god-object (toolbar and the split delegate are
already extracted), broaden localization, and enable the extension runtime once
there is real demand (the seam and manifest schema are in place but gated off).
