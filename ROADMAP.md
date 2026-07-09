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

## Round 2 (all shipped, 2026-07-08)

Round 1 (below) and now all of round 2 are shipped, committed, and installed. Built
in order (tractable first; the biggest, most architectural last):

1. **Global instant filename search** -- SHIPPED (2026-07-08). Go > Find Files
   Everywhere (Cmd-Shift-O): a floating palette that Spotlight-searches file names
   as you type (debounced, stale-guarded), with results (name + location); Enter or
   double-click reveals the file in the active pane (navigate + select).
   `SpotlightSearch.filenameQuery` (tested). Follow-up: scope picker + a `find`
   fallback for non-indexed locations.
2. **macOS Shortcuts -- run a Shortcut on the selection** -- SHIPPED (2026-07-08).
   Tools > Run Shortcut on Selection lists installed shortcuts (`shortcuts list`,
   loaded off-main) and runs the chosen one once per selected file
   (`shortcuts run <name> --input-path <file>`), out-of-process via `ShortcutsRunner`,
   output in the shared command-output panel. External tool only. Follow-up:
   exposing Pathem's own actions AS Shortcuts (App Intents target).
3. **AI rename / summarize folder / semantic dedup** -- SHIPPED (2026-07-08).
   **Semantic dedup**: View > Find Similar Names groups files with semantically
   similar names via the on-device `NLEmbedder` (cosine over extension-stripped base
   names), complementing the byte-identical `DuplicateFinder` -- new `SemanticDedup`
   engine, 5 unit tests. **AI rename / summarize** (FoundationModels, gated on macOS
   26 + model readiness, graceful "unavailable" otherwise): File > AI Rename proposes
   a filename from a text preview and fills the normal rename sheet the moment it
   lands (latency never blocks), applying through the existing rename + undo path;
   View > Summarize Folder describes a folder from its item names in the output panel.
   New `AIAssistant` engine (pure reply-sanitizer unit-tested). Verified available on
   this Mac via the smoke availability probe.
4. **Multi-window / detachable tabs** -- SHIPPED (2026-07-08). File > New Window
   (Cmd-N) opens independent browser windows via a new `WindowManager`; each has its
   own panes/tabs/terminal. Only the primary window restores/saves the session (new
   `persistsSession` flag), so siblings never clobber its tabs. Move Tab to New Window
   detaches the active tab; a shared tabbing identifier + a standard Window menu give
   native Merge All Windows / drag-to-detach. Quit tears every window's shell down.
   Covered by app smoke + a `PATHEM_MULTIWINDOW_SMOKE` end-to-end path.

Also shipped (2026-07-08, by request): **Copy Path / Copy Name in the right-click
menu everywhere** -- both were previously only in the Edit menu + toolbar; now in the
shared context menu across all views. Copy Path also handles remote panes
(server-side paths); Copy Name reads entry names directly (local, remote, smart).

Polish backlog from round 1/2: streamed (not buffered) external-command output;
saved smart folders shown in the sidebar; Group By in the icon view; a Tag group
key; collapsible group sections; filename-search scope picker + `find` fallback;
Shortcuts as App Intents; AI-rename batch preview.

## Round 3 (shipped 2026-07-08)

Four clusters, built in order. Nearly all shipped; a few items deferred with reasons.

- **3A View parity** -- SHIPPED. Tag color dots + git status badges in the
  grids/column (shared `PaneDecorationCache` + `FileNameDecoration`); single-click
  open + hover underline in the grids; super-drag flick + swipe trail in
  icon/gallery/column; drag-move-by-default for icon + column. Every non-list view
  is now first-class.
- **3B Finder-parity features** -- SHIPPED. Slideshow (`SlideshowController`,
  full-screen, timer + keys); Quick Actions Rotate Left/Right + Create PDF (PDFKit);
  Show Original for an alias/symlink; spring-loaded folders (list). *Deferred:*
  Markup + Trim (need interactive Quick Look markup / AVFoundation UIs); spring-load
  in the grids (they drop into the current folder, not sub-items).
- **3C Group By + polish** -- SHIPPED. Collapsible group sections (disclosure +
  count); a Tag arrange key; saved smart folders in the sidebar; streamed
  external-command output (`runStreaming`); filename-search scope picker (This
  Mac / Home / This Folder). *Deferred:* Group By in the icon view (needs a
  sectioned NSCollectionView refactor of the flat indexPath model).
- **3D Power-user batch** -- SHIPPED (gaps only). Batch Finder-comment editing
  (`FileMetadata.setFinderComment`) and Connect to Server (Cmd-K, arbitrary
  smb/afp/nfs URL via NetFS). Batch chmod already shipped (Set Attributes),
  discovered-share SMB mount already shipped, and light/dark/system appearance
  theming already ships. *Deferred:* chown/ACL editing (limited without privilege
  escalation); per-app accent/skins (no clean public API).

## Round 3.5 (shipped 2026-07-08) -- theming + deferred cleanup

Cleared the tractable deferrals from round 3, plus theming the user asked for.

- **App-wide skins** -- `ThemePreset` (10 presets) + `ThemeManager`; the accent
  tints every Pathem-drawn element (list/grid selection, active pane border, active
  tab, breadcrumb), a window tint, and a Settings picker with custom color wells.
- **Per-folder backgrounds** -- a color or picture behind the list per folder
  (`FolderBackground`, View ▸ Folder Background), across all four views.
- **Icon sets** -- swappable icon themes (`IconSet` + `IconSetManager`): System,
  Monochrome, Vivid, Blueprint; overrides the NSWorkspace lookup in all views.
- **Spring-load in the icon grid** -- the grid already dropped onto folders, so it
  now springs too.
- **Trim** -- `TrimController` (AVPlayerView.beginTrimming + passthrough
  AVAssetExportSession), File ▸ Transform ▸ Trim Media.
- **ACL editing** -- `ACLEditor` (chmod +a/-a#) + a panel; adds/removes access
  control entries. Complements the existing ACL reader.
- **Group By in the icon view** -- the deferred sectioned-NSCollectionView refactor,
  done: a section model + a two-way indexPath<->entry mapping.
- **Ownership** -- Set Attributes ▸ Group changes the group without root
  (`BulkAttributes.groupOwnerName`); Change Owner (Admin)… types a `sudo chown` line
  into the embedded terminal (`OwnershipEditor` + `TerminalController.typeCommand`),
  so chown-to-another-user works without a bundled privileged helper.

*Still deferred:* a signed `SMAppService` privileged helper (only needed to avoid the
terminal password prompt; the terminal route covers the use case). Markup (needs an
in-app annotation editor). Per-app accent for *standard* AppKit controls (no public
API; only Pathem-drawn chrome is themed).

## Round 4 (scheduled, 2026-07-08) -- new views

Each new view is a `PaneContentView` conformer plus a `ViewMode` case, so they don't
touch the rest of the app:

- **Tree / outline view** -- expandable folders inline in the pane (NSOutlineView),
  so a subtree is visible without losing the parent (Directory Opus-style).
- **Flat / recursive view** -- every file under the current folder flattened into one
  list, built on the existing `FlatEnumerator`; for bulk ops across a subtree.
- **Commander mode** -- an orthodox function-key bar (F1-F8 hints) + an integrated
  command line over the existing dual pane (F5 copy / F6 move already ship). A toggle,
  not a new view.
- **Save named view presets** -- first-class "save this view as a named preset"
  (columns/sort/grouping/zoom) over Saved Views + `ViewFormat`; the precursor to true
  plugin-defined custom views (which wait on the gated Swift extension runtime).

## Next up -- round 1 (shipped 2026-07-08)

All four shipped, committed, and installed. Details for each live in their existing
sections below (Candidate features / Recently requested / Site manager).

1. **User-defined external commands** -- SHIPPED (2026-07-08). Tools > External
   Commands lists your commands (one click to run) with a Manage editor; each is
   also a registry command (palette + bindable in Settings > Shortcuts). A command
   is a shell template with `%F` (selected paths), `%N` (names), `%D` (this folder),
   `%P` (parent), `%%` literal; paths are shell-quoted. Runs out-of-process via
   `/bin/sh` off the main thread, output in a panel with a Stop button. Engine core
   (`ExternalCommand` + `ExternalCommandRunner`, 5 unit tests) + app store /
   registration / editor. Follow-up: streamed (not buffered) output, a
   context-menu group.
2. **Undo history + selective undo** -- SHIPPED (2026-07-08). All six file-op
   register sites (move/copy, trash, new-item, rename, created-batch,
   new-folder-with-selection) plus the Edit menu and Cmd-Z/⇧Cmd-Z now run through
   `ActionHistory` instead of `NSUndoManager` (text-field editing keeps its own
   field-editor undo, routed by `isEditingText`). Each action records a path
   footprint; **Edit > Undo History…** lists recent actions with **Undo This** --
   a selective undo of an action nothing newer touched (footprint-overlap check).
   Smoke covers the model, selective undo, and a real move -> undo round-trip.
3. **SFTP private key file + passphrase** -- SHIPPED (2026-07-08). `RemoteConnection`
   gains a `keyFile` (forward-compatible decode); the SFTP backend passes
   `-i <key> -oIdentitiesOnly=yes` (tilde-expanded, argv-separated so a path can't
   smuggle an ssh option), and the connect prompt asks for the key's passphrase
   (via the existing SSH_ASKPASS path) instead of a password. The site manager has
   a Key File field + Choose… (opens in ~/.ssh, shows hidden files). Keychain
   password/passphrase saving already existed (the Remember checkbox).
4. **Advanced find / smart folders** -- SHIPPED (2026-07-08). View > Advanced Find
   (Cmd-Opt-F): a builder over Spotlight `mdfind` -- name, extension, kind, content,
   tag, min size, modified-within -- with Search (results in the active pane) or
   Save as Smart Folder (persisted to searches.json, re-registered as a palette /
   bindable command). SavedSearch gained content + tag criteria (unit-tested).
   Follow-up: surface saved smart folders in the sidebar.

Bigger bets deliberately left for after these: macOS Shortcuts integration, AI
rename / summarize / dedup, multi-window, SMB/AFP mount, app-wide theming.

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

## Site manager / remote (FileZilla Pro parity, added 2026-07-05)

The remote backends (S3, WebDAV, SFTP, FTP) and a FileZilla site import ship
today, but the site manager itself is minimal: name, protocol, host, port, user,
initial remote path, S3 region, with the password prompted each connect and one
global speed cap. Closing the gap toward FileZilla Pro, by priority.

Tier 1 (auth and security; cheap on the existing SFTP/FTP code):

- **SFTP private key file + passphrase** -- SHIPPED (2026-07-08). Key File field
  in the site manager; `-i <key> -oIdentitiesOnly=yes`; passphrase via SSH_ASKPASS.
- **Save passwords in the Keychain** -- already shipped (the "Remember password"
  checkbox on connect, per connection id via KeychainStore).
- **FTPS** (FTP over TLS), explicit and implicit.

Tier 2 (organization and power):

- **Folders / groups + search** in the site list.
- **Per-site color labels.**
- **Per-site default local directory** and **synchronized browsing** (both panes
  move together).
- **Bookmarks:** saved local-to-remote path pairs per site.

Tier 3 (breadth and niceties):

- More cloud backends: **Backblaze B2, Azure Blob, Google Cloud Storage** (the S3
  code is the template).
- FTP **passive / active** mode and charset / encoding.
- Per-site speed limits, keep-alive / reconnect, SOCKS / HTTP proxy.

## Recently requested (in flight / backlog, 2026-07-05)

- **Undo history + selective undo** -- SHIPPED (2026-07-08). See "Next up".
- **Easy folder-icon change from folder properties** (Get Info).
- **Cloud folder badges:** keep the real folder icon (an iCloud "Documents" still
  shows the Documents glyph) and overlay a small cloud-service badge, iCloud via
  SF Symbol plus bundled brand logos for Dropbox / Drive / OneDrive under
  nominative use, generic cloud fallback otherwise.
- **Super-drag follow-ups:** make the flick-to-command map user-editable, and
  extend the gesture beyond the list view (icon / gallery / column).

## Candidate features (demand-ranked, added 2026-07-05)

Broader backlog beyond the site-manager and in-flight items, ranked by how much
each would move power users to switch. Not yet scheduled.

Automation hub (most switch-driving):

- **User-defined external commands:** run your own scripts / CLI tools on the
  selection with placeholders (`%F`, `%P`, the selection list), bound to the
  toolbar / menu / keymap. External tools, not embedded scripting, so within the
  hard rules.
- **macOS Shortcuts integration:** expose Pathem actions to the Shortcuts app,
  and run a Shortcut on the selection.

Search:

- **Advanced find / filter builder** -- SHIPPED (2026-07-08, View > Advanced
  Find). See "Next up". Remaining polish: show saved smart folders in the sidebar.
- **Global instant filename search:** indexed, whole-disk, sub-100 ms
  ("Everything"-style).

AI (the on-device differentiator):

- **AI rename** (names from content / EXIF), **summarize this folder**, and
  **semantic dedup** (near-duplicate detection beyond byte-identical), built on
  the existing on-device model + embeddings.

Batch and metadata:

- **Batch permissions / ownership** (chmod / chown / ACL) across a selection.
- **Batch Finder-comment editing.**

Connectivity:

- **One-click SMB / AFP mount** from discovered network shares.
- **Services / Quick Actions** exposure and a proper "Open with Pathem" target.

Quality of life:

- **Detachable / multi-window** and drag-a-tab-out.
- **App-wide theming** (accent / skins) beyond the terminal themes.
- **Transfer queue:** queue-level **pause/resume**, **retry failed**, and
  **clear all** shipped (2026-07-07) in the Transfers window; **checksum
  verification** of copies shipped (2026-07-08, opt-in via Settings > General,
  SHA-256 re-read after each copied file). Remaining: pausing an in-flight
  transfer to resume mid-stream (needs provider range/reget support), and
  verifying remote downloads (needs a server-provided checksum).
- **Vim-style, fully keyboard-driven** navigation mode.

## Finder parity audit (2026-07-05)

A pass over Finder's own File / Go / View / context menus against Pathem's
command registry. Most table stakes are already covered: open + open-with,
trash + restore, duplicate, make alias / symlink / hardlink, compress + extract,
Get Info plus a live-updating inspector, color tags, Quick Look, Reveal in
Finder, batch rename, saved searches, path / status bars, a customizable
toolbar, AirDrop, Share, and Connect to Server. The gaps below are the ones a
Finder user would actually reach for and miss, ranked by effort.

Quick wins (compose existing FileOperations; each is a command plus menu wiring):

- **New Folder with Selection (N Items)** -- SHIPPED (2026-07-07). Ctrl-Cmd-N,
  in the File and (shared) context menus with a live pluralized count
  ("New Folder with Selection (3 Items)"); one undoable action (create + move,
  undo moves back out and trashes the folder). Follow-up: auto-enter inline
  rename on the new folder (today it just selects it, matching plain New Folder).
- **Empty Trash + Put Back + Delete Immediately** -- SHIPPED (2026-07-08). The
  Trash is a browsable sidebar location; in it, per-item **Put Back** restores to
  the original path (via a persisted origin ledger Pathem writes when it trashes;
  Finder-trashed items have no recorded origin), and **Delete Immediately**
  (Cmd-Opt-Delete) / **Empty Trash** (Cmd-Shift-Delete) erase permanently behind a
  cursor-anchored confirm.
- **Open a folder in a new tab** -- SHIPPED (2026-07-08), in the File and context
  menus (shown for a single selected folder). Open-in-**new-window** still waits
  on multi-window (a separate candidate).
- **Recent Folders** -- SHIPPED (2026-07-08). Go > Recent Folders lists the last
  20 visited folders (persisted, deduped), each navigates the active pane, with
  Clear Menu.
- **Set Desktop Picture** -- SHIPPED (2026-07-08). Context menu on a single
  selected image sets it on every screen (NSWorkspace.setDesktopImageURL).

Larger (new UI or a view-layer change):

- **Group By / Arrange By** -- SHIPPED (2026-07-08) for the list view. View >
  Arrange By groups rows under section headers by Kind / Size / Date Modified (or
  None), persisted per folder in ViewFormat. Implemented as a display-row model
  (`FileGrouping`): `entries` stays the ungrouped source and every row<->entry
  touch point (selection, drag, hover, per-row reloads) maps through it, so the
  ungrouped path is unchanged. Follow-ups: group in the icon view too, a Tag
  group key, and collapsible sections.
- **Slideshow** -- a full-screen Quick Look slideshow of the selected images.
- **Built-in image / document Quick Actions** -- Rotate Left / Right, Create PDF,
  Markup, Trim, beyond the existing Convert Images / Compress. Overlaps the
  Services / Quick Actions candidate above; these are Finder's bundled ones.
- **Show Original** for an alias or symlink (jump to the target and select it).
- **Spring-loaded folders** -- hover a drag over a folder to spring it open, so a
  drag can descend a tree without dropping first.
- **Merge All Windows** once multi-window lands (folds into the multi-window
  candidate).

Deliberately skipped: Burn Folder / Burn to Disc (obsolete); a dedicated New
Smart Folder builder is already covered by saved searches plus the planned
advanced-find / smart-folder item above.

## View parity: icon / gallery / column vs list (audit + progress, 2026-07-05)

The list view was the most complete; the other three had accumulated gaps. The
`PaneContentView` protocol's no-op defaults are the precise inventory. Closing
them modularly (shared helpers, not per-view copies), tracked here.

Done:

- **Right-click menu** -- all four views now share one `FileContextMenuController`
  (structure + Open With + Tags + archive-gated Extract), so they can never drift
  again. Column view had no menu at all before.
- **Cut dimming** (`setCutPaths`) -- icon, gallery, and column now grey cut items
  until pasted, keyed via a shared `PaneItemKey`.
- **Quick-actions bar anchored to the selection** (`selectionRectInWindow`) --
  icon, gallery, and column now report their selection rect, so the bar hugs the
  selection instead of centering on the pane.
- **Git status letters** (`setGitStates`) -- the column view now prefixes the
  colored git letter, via a shared `FileNameDecoration` the list also uses.

Remaining:

- **Tag color dots** -- still list only; needs the async tag-color cache
  (`invalidateTagCache`) wired into the grid/column cells, then reuse
  `FileNameDecoration` (grids need a badge overlay rather than an attributed
  string).
- **Git letters in the grids** -- icon/gallery need a small badge overlay on the
  item rather than the attributed-string prefix the tables use.
- **Single-click open + hover underline** (`setClickBehavior`): list only.
- **Super-drag flick + swipe trail** (`onDragSession`): list only (also under
  "Super-drag follow-ups").
- **Drag move-by-default** (`dragMovesByDefault`): list and gallery move between
  folders by default; icon and column always copy (needs each view's drop logic
  to resolve the operation like the list's `resolvedDragOperation`).

Inherent to the layout (not gaps to close): the list's sortable column header +
sort indicator and its extended metadata columns (size / date / kind / xattrs),
and the grids' thumbnail zoom.

## Hard rules (unchanged)

Non-sandboxed + Full Disk Access; clean Hardened Runtime (no
disable-library-validation, no allow-jit); Swift-only extensions, no in-process
foreign bundles, no embedded scripting; stdlib-first; MIT; on-device semantic
search stays free forever. Cloud/remote networking lives out-of-process, never in
the FDA process. Bundled dependencies stay permissive; never copy GPL code.
