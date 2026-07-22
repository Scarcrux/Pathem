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
commandem init . && commandem add . && commandem brief --apply    # constellation
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

<!-- commandem:managed:start -->
<!-- Managed by `commandem brief`. Do not edit between these markers;
     edit the commandem directives file and re-run `commandem brief`. -->

## Polaris

This project is tracked by **polaris**, a cross-project command
center. Its machine contract is `polaris.toml` at the repo root
(mode, commands, conventions - see it / SPEC.md). Polaris
coordinates status and dispatch across projects and propagates
the standing directives below to every tracked project.

### Standing directives

## iCloud hygiene

Exclude only regenerable/churny dirs from iCloud via the `.nosync`
trick. Source files then dual-back-up to iCloud + GitHub harmlessly.

Empirical refinements (post-reboot conflict experience):

- **For non-regenerable load-bearing dirs (notably `.git`): use git's
  native gitdir pointer file, NOT a symlink.** iCloud reconciliation
  can evict symlinks across reboots; a plain text file syncs cleanly.
  Mechanism: `mv .git .git.nosync && printf 'gitdir: .git.nosync\n' >
  .git`. Git natively follows the pointer (same machinery as
  worktrees/submodules). Add `.git.nosync/` (and any other in-tree
  `.nosync` dirs) to `.gitignore` so git doesn't track its own
  metadata.
- **For regenerable dirs (e.g. Swift `.build`): the symlink trick is
  fine, but the build script must self-heal** — before invoking the
  tool, verify `.build` is a symlink to `.build.nosync` and re-create
  it if missing/broken. Otherwise the next build materializes the
  churny dir back into iCloud and the conflict storm returns.
- **A `* [0-9].*` filename anywhere in the source tree (e.g.
  `chat 2.go`) is an iCloud conflicted-copy.** The real file is in
  git; the duplicate is stale. Sweep + remove. Heavy write churn
  (rapid builds + commits) is what spawns them; the two redirects
  above are the main prevention.

## Keep the roadmap current

The roadmap is a requirement, not a courtesy. When you complete or
materially advance a phase, update it in the SAME session via
`commandem roadmap <project>` — mark finished tasks/phases done, flip the
phase you are working on to `now`, and add a new phase for new work you
took on. Do not let shipped work go unrecorded, and do not wait to be
asked.

A healthy roadmap always names current work: at least one phase in `now`
or `next`. `commandem health` flags a roadmap with none (the
`roadmap current` check), so an un-maintained roadmap surfaces in the
attention view. Record the roadmap edit as part of finishing the work,
the same way tests and a rebuild are part of it — not an optional
afterthought.

## Container runtime: OrbStack

All projects that use Docker or containers should migrate to
[OrbStack](https://orbstack.dev/) if they haven't already. OrbStack
replaces Docker Desktop on macOS with dramatically lower resource
usage, faster startup, and native Rosetta x86 emulation on Apple
Silicon. Migration checklist:

- Install OrbStack (`brew install orbstack` or download from site).
- Uninstall Docker Desktop (OrbStack is a drop-in replacement;
  existing images/volumes migrate automatically on first launch).
- Verify `docker` and `docker compose` commands work unchanged
  (OrbStack provides compatible CLI shims).
- Update any CI/local scripts that reference Docker Desktop paths
  or the Docker Desktop VM directly.
- If the project uses Dockerfiles or compose files, no changes
  needed -- OrbStack runs them as-is.
<!-- commandem:managed:end -->
