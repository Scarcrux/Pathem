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
Scaffold only. `PathemEngine` has a `FileEntry` value type and a
`FoundationEnumerator` (the correct-but-slow reference impl + test oracle); the
app is a stub window.

## Next milestones (DESIGN.md §5)
1. **`BulkEnumerator`** — the `getattrlistbulk` hot path, contract-tested
   against `FoundationEnumerator`.
2. **Gate A** — view-based `NSTableView` scrolling a synthetic 1M-entry
   directory at 120fps.
3. **Gate B** — lazy `NSOutlineView` expanding a 100k-child node with no
   main-thread stall.
