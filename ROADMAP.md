# Pathem roadmap

Living document. Goal: ship a focused, launch-ready **v1.0 this week** (week of
2026-06-22), then fast-follow with remote/cloud transfer. Grounded in two
multi-agent design passes (a launch-readiness audit and a cloud-storage
architecture study), machine-verified on macOS 26.

## Current state

The hard part is done and verified in source: getattrlistbulk fast enumeration
(Gate A virtualizes 1M rows), an FSEvents watcher, dual-pane + tabs + a
Finder-style sidebar, per-folder saved views + apply-to-subfolders, Layouts, a
command registry + rebindable keymap + command palette, on-device semantic
search + an AI command bar, Quick Look, batch rename, preferences, and
copy/move/cut/paste with undo. Universal .app packaging. Clean build, 88 engine
tests.

What is missing for a credible v1.0 is not architecture. It is a cluster of
table-stakes actions and a few reliability fixes.

## v1.0 must-haves (this week)

- **Open a file in its default app** (today a non-folder double-click/Return is a
  no-op, which alone makes Pathem unusable as a Finder replacement).
- A real **File / Go / View menu**, bound to the command registry.
- **New Folder** (Cmd-Shift-N).
- **Move to Trash** (Cmd-Delete), with undo.
- **Preserve selection + scroll across reload** (sort, file op, watcher tick).
- **Off-main copy/move** with a progress + cancel sheet (no main-thread freeze).
- **Right-click context menu** (Open / Trash / New Folder / Rename / Reveal / clipboard).
- **Single-file inline rename**.
- **Distinct empty / permission-denied states** + a first-run Full Disk Access
  prompt + a README FDA note.
- **Reveal in Finder**.
- **Clear the search field** on pane change / navigation.
- **App icon** wired into the bundle.

## The week

- **Day 1 (Mon):** open files; real File/Go/View menus; New Folder; Move to Trash.
- **Day 2 (Tue):** preserve selection/scroll across reload; clear stale search; inline rename.
- **Day 3 (Wed):** off-main copy/move with progress + cancel (the keystone, front-loaded).
- **Day 4 (Thu):** context menu; empty/permission states; first-run FDA prompt; Reveal in Finder.
- **Day 5 (Fri):** app icon; notarize dry-run; palette/keymap smoke test.
- **Day 6 (Sat):** hardening, full manual pass, README, tag v1.0, cut the notarized download. Deliberate slack.

## Cloud: Tier 1 in v1, the rest is fast-follow

Cloud-**aware**, not cloud-mounting (verified on this machine).

- **Tier 1 (cheap, fold into the week):** the OS already mounts
  iCloud/Dropbox/Drive/OneDrive under `~/Library/CloudStorage/`, and Pathem
  browses them today. Add `isDataless` (one bit-test on the `st_flags`
  BulkEnumerator already reads, zero extra syscalls) and **gate content reads
  (semantic-index extraction, Quick Look) on `!isDataless`** so browsing a cloud
  folder never silently downloads online-only files. Stretch: a sync badge,
  CloudStorage entries in the Places sidebar, and a Download command
  (`startDownloadingUbiquitousItem`, verified, no entitlement).
- **Tier 2 (post-bundle):** `NSFileProviderManager` grouping + a Free Up Space
  (evict) command.
- **Remote transfer (Pro / fast-follow):** an async `FileProvider` engine seam
  with S3 / WebDAV / SFTP networking in an **out-of-process signed XPC helper**,
  never in the Full-Disk-Access process. No FUSE, ever.

## Fast-follow (post-v1.0)

- Cloud Tier 2 + remote transfer panes (S3 / WebDAV / SFTP), the FileZilla /
  ForkLift lane, as Pathem Pro.
- Drag-and-drop (within app and to/from Finder).
- Get Info inspector; Open With submenu.
- Unified title-bar NSToolbar; window-state restoration.
- Sparkle auto-update appcast (EdDSA).
- Torrents: far-future optional add-on (BSD libtorrent-rasterbar, out-of-process helper).

## Hard rules (unchanged)

Non-sandboxed + Full Disk Access; clean Hardened Runtime (no
disable-library-validation, no allow-jit); Swift-only extensions, no in-process
foreign bundles, no embedded scripting; stdlib-first; MIT; on-device semantic
search stays free forever. Cloud/remote networking lives out-of-process, never in
the FDA process. Bundled dependencies stay permissive; never copy GPL code.
