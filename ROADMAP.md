# Pathem roadmap

Living document. The product is built: a dual-pane manager with fast enumeration,
file ops + undo, five views, on-device search, remote/cloud backends, a native
torrent engine, an embedded terminal, deep customization, and Sparkle updates
(the full shipped history is in the rounds below). A multi-agent correctness and
security audit has been run and its findings fixed.

The focus now is a **launch runway**, described in the next section: refine the
app and site to public-launch quality so that the day the repository is flipped
public, it converts visitors into stars and users. The repo is intentionally kept
private until more user testing is done, so nothing here is blocked on that flip,
and everything here makes the flip land better.

## Now (2026-07-12): the launch runway

Five tracks, roughly in priority order. **Tracks A (app polish), B (site), and C
(localization hygiene) are done** (see their status blocks) -- the pre-launch
runway is complete. **Track D (the public flip) is the next step, gated on the
user's testing decision;** E is the post-launch backlog. Meanwhile, live-app
feedback keeps landing as dated rounds below (latest: Round 14).

### Track A -- App polish (refinement, not new features)

Grounded in a fresh-eyes UX survey. Ordered by impact over effort. The first item
is the keystone: it unlocks several others.

> **Status (2026-07-21).** Much of this shipped without being marked here. **Done:**
> 1 (the `flashStatus` / `flashCopied` transient channel), 2 (copies now flash
> "Copied N"), 3 (empty-state copy consolidated to `pane.folderEmpty` /
> `pane.noMatchesFor` everywhere), 4 (the permission-denied placeholder has an Open
> Full Disk Access button, and the FDA guide no longer styles its "Not Now" dismiss
> as the primary action). **Largely done:** 5 (the chrome accent sites now read
> `ThemeManager.shared.accent`, the skin accent, not the hardcoded
> `.controlAccentColor`), 9 (git badges + tag dots are wired in the icon and gallery
> grids), 7 (the ACL row already reads "Permissions", the raw curl error is already
> softened to "connection failed (code N)"; only the octal `644` placeholder remains,
> and it's fine in a field labelled "octal"). **Partly done:** 6 (transfer-busy /
> connection-failed already flash; the three cases that hid a real reason -- a
> transfer already running, a remote-only op refused (`blockedByRemote`), and an Info
> toggle that failed on permissions (`reportToggleFailure`) -- all now show a message
> or alert, and a scan found no `beep()` inside a `catch` swallowing an error. The
> remaining `NSSound.beep()` calls are the fine "not applicable" guards the item
> itself carves out.), 9 (single-click-to-open is now honored in every view including
> column and tree; hover-underline stays list/icon/gallery-only by design, low value
> in the dense column/tree).
>
> **Track A is substantively done.** The only remaining tail is item 8's "over time"
> work -- accessibility labels on the custom-drawn cells (the functional glyphs and
> controls are all labelled). Track A can move off `now`; with Tracks B (site) and
> C (localization) also done, the Track D public-flip gate is the remaining launch
> work, gated on the user's testing decision.

1. **A transient-status channel (toast/HUD).** There is no app-wide way to show a
   brief confirmation or a soft failure. Build one small helper that reuses the
   per-pane status label (`PaneController.statusLabel`). This is the root fix
   behind items 2 and 6, and it is a medium-size change that turns a pile of
   silent successes and beep-only failures into cheap wins.
2. **Confirm silent successes.** Copy Path / Copy Name / Copy Checksum write to
   the pasteboard and return with no feedback. Flash "Copied 3 paths" via the new
   channel. (`BrowserViewController+SelectionInspection.swift`.)
3. **Consolidate empty-state copy.** "Empty folder" / "This folder is empty" /
   "No items" all mean the same thing; likewise "No matches for X" vs "No matching
   files". Pick one of each.
4. **Make the permission-denied placeholder actionable.** The read-failure state
   tells the user to open System Settings but gives no button; add one that opens
   Full Disk Access (or re-triggers `FullDiskAccessGuide`). Also fix the FDA guide
   button hierarchy (the primary slot currently holds "Not Now").
5. **Fix themed-accent drift.** Several custom-drawn elements hardcode
   `.controlAccentColor` and ignore the skin accent, so with a custom theme half
   the chrome matches and half does not: QuickActions tint, size-bar fill,
   transfer-progress color, the AI sparkle, the FDA step badge.
6. **Turn meaningful beep dead-ends into messages.** Roughly ninety
   `NSSound.beep()` guards exist; most are fine "not applicable" guards, but the
   ones that hide a real reason (a transfer already running, a remote-only op
   refused, an Info toggle that failed on permissions) should say so.
7. **Soften a few raw/technical strings.** A verbatim remote/engine error can
   reach the pane placeholder; the ACL row is labelled "Sharing" (reads as the
   share sheet) when it means Permissions; `curl error %d` and octal `644`
   placeholders leak tool internals.
8. **Accessibility labels, incrementally.** There are currently no explicit
   accessibility labels anywhere; start with the functional image-only glyphs
   (sidebar collapse chevron, gallery cloud-download badge, pane toolbar buttons),
   then the custom-drawn cells over time.
9. **Close the view-parity gaps** (highest-impact of the "partial" items, medium
   each): tag color dots and git badges in the icon/gallery grids, and honoring
   the single-click-open / hover-underline preference outside the list (today it
   silently no-ops there, which is a trust problem).

### Track B -- Website & conversion

1. **Optimize `social-card.png`** (currently 610 KB, 4-8x heavier than needed for
   an OG card).
2. **Show, do not just tell.** The feature grid describes torrents, the terminal,
   and remote/site-manager in text but never shows them, while the five view modes
   get a whole carousel. Add real screenshots for the marquee features.
3. **An honest download story.** The primary CTA is "Star on GitHub" with a
   "downloads soon" note; keep it honest until there is a notarized build, then
   wire a real download + the Sparkle appcast.
4. **Minor SEO/PWA polish:** a web app manifest, an SVG favicon, and a sitemap
   date refresh.

**Status (2026-07-21):** Items 1, 2, and 4 are done. `social-card.png` is 123 KB
(down from 610), with complete Open Graph + Twitter `summary_large_image` meta
(image, 1200x630 dimensions, alt text). The marquee features now have real framed
screenshots (torrents, terminal, remote, markup) alongside the view carousel.
SEO/PWA is in place: `site.webmanifest`, an SVG favicon plus PNG/apple-touch
icons, and the sitemap `lastmod` refreshed to 2026-07-21. Only item 3 remains,
and it is deliberately gated: the CTA stays "Star on GitHub" until there is a
notarized public build to link (Track D), then it wires a real download + the
Sparkle appcast. Track B is done except that launch-gated download link.

### Track C -- Localization hygiene (before launch)

The catalogs had drifted: `en.lproj` had 812 keys, the other five locales carried
about 1,502 each, and roughly 692 of the 1,406 `L()` keys referenced in code lived
only in the inline English fallback. The plan: extract every referenced key, prune
stale entries, ensure all six languages cover every key, then add a coverage +
`plutil` lint to the pre-commit hook so it cannot rot again.

**Status (2026-07-22): done.** `scripts/l10n_lint.py` extracts the canonical key
set from the code, `--fix-en` regenerates `en.lproj` from the inline fallbacks
(source of truth) and prunes truly-dead keys, and `--merge` pulls the other five
locales from `scripts/l10n_missing.json`. The lint is green: 1488 canonical keys,
0 missing / 0 stale across en/fr/de/es/ja/zh-Hans, and it runs in pre-commit (the
`l10n-lint` hook, on any `.swift`/`.strings` change) so a new `L()` key that isn't
translated fails the commit. The counts in the paragraph above are the historical
starting point, not the current state.

### Track D -- The public flip (gated on user testing)

Not to be done until the user says the testing gate is met. When it is: a final
manual QA pass, confirm the screenshots are current, cut a notarized direct
download with an EdDSA-signed Sparkle appcast (so the site has a real download),
final pass over README / LICENSE / SECURITY, then flip the repo public so the site
starts converting. Define the user-testing exit criteria explicitly first.

The go/no-go gate, QA pass, and flip sequence are drafted as a working checklist
in **[LAUNCH_CHECKLIST.md](LAUNCH_CHECKLIST.md)** (build mechanics stay in
**[RELEASE.md](RELEASE.md)**); review and adjust the exit-criteria thresholds
there, then work it top to bottom when the gate opens.

### Track E -- Post-launch engineering bets

- Finish dissolving the `BrowserViewController` god-object. Extracted so far: the
  toolbar, split delegate, semantic search (`+SemanticSearch.swift`), inter-pane
  transfers / openers (`+PaneTransfers.swift`), Copy To / Move To + recents
  (`+CopyMoveTo.swift`), and the on-device AI actions -- rename / summarize /
  command bar (`+AICommands.swift`). The core file is down from ~1,932 to ~1,560
  lines; the shared transfer plumbing (`runTransfer` / `resolveThenTransfer`) is now
  cleanly separate. What's left is mostly genuine controller work (init, wiring,
  lifecycle, remote-op guards) plus scattered helpers that don't form clean cohesive
  blocks -- so this is a good stopping point; further cuts would be churn, not wins.
- Torrent standalone-client parity. **Done (verified 2026-07-23):** all four are
  implemented, wired, and unit-tested in TorrentKit -- send-side PEX
  (`TorrentSession` sends `PEX.message`; `handshakeAdvertisesAndParsesUtPex`), a
  persistent DHT routing table (`DHTClient.routingTableData`/`loadRoutingTable`,
  saved by `TorrentEngine`; `routingTablePersistsGoodNodes`), UPnP-IGD fallback
  (`TorrentEngine` maps via NAT-PMP, else UPnP), and delay-based LEDBAT congestion
  control for uTP (`UTPSocket.grow(bytesAcked:)`, RFC 6817;
  `congestionWindowGrowsBelowTargetShrinksAbove`). This bullet was stale; the work
  had shipped. (Fixed a misleading "simple fixed window" comment left in `UTPSocket`.)
- Enable the gated Swift extension runtime once there is real demand (seam and
  manifest schema are in place).

### Track F -- Finder handoff & editor integration (fast-follow feature)

Post-launch. Strengthens the "other apps hand off to Pathem, not Finder" story.
The folder-open handler already redirects "open this folder"; "Reveal in Finder"
cannot be intercepted system-wide (it targets Finder by identity, with no
LaunchServices role to claim), so the rest is a "pull" model plus opt-in wiring.

- **A `pathem` CLI reveal/open contract** (`pathem reveal <path>`,
  `pathem open <dir>`) as the stable seam every integration calls, so the launch
  logic can change without touching any editor config. **Done (2026-07-23):** the
  `pathem-cli` executable target resolves a path and drives the app over a new
  `pathem://open|reveal?path=` URL scheme; the scheme, verbs, and query live in one
  place -- `PathemURLContract` (engine, unit-tested) -- shared by the CLI and the
  app. Registered in `Info.plist`, bundled by `package.sh`. Remaining tail: an
  on-PATH `pathem` symlink install (folded into the Integrations panel below, since
  `pathem` can't sit in `MacOS/` next to `Pathem` on a case-insensitive volume).
- **Reveal in Pathem** -- a second `NSServices` item plus a select-and-reveal
  handler (navigate to the parent, select the target), beside the existing
  "Open in Pathem" service. **Done (2026-07-23):** `revealInPathem` Service +
  `revealExternalItem` handler; smoke-checked that reveal lands in the parent, not
  inside the item.
- **Preferences ▸ Integrations** -- detect installed editors and offer per-editor
  Integrate / Preview / Remove. Editing a third-party config is invasive, so:
  opt-in only, preview the exact change first, back up and make it reversible,
  merge (never clobber) the existing file, warn if the editor is running, atomic
  writes, all inside `~/Library`. **Partial (2026-07-23):** the pane exists
  (`Settings ▸ Integrations`) with the non-invasive core -- a one-click install of
  the on-PATH `pathem` command (`PathemCLIInstall`: picks the first writable PATH
  dir, only ever creates/removes a symlink it owns, never clobbers a real file;
  smoke-checked) and a read-only list of detected editors. Still to do: the
  invasive per-editor Integrate/Preview/Remove with the backup/reversible/atomic
  machinery (next bullet).
- **Per-editor mechanism.** Sublime Text (a small User-package plugin + keymap +
  side-bar menu), TextMate (a bundle command), and JetBrains (an External Tools
  entry) can be wired by writing their own config -- a true "change the editor's
  preference files" path. VS Code and Cursor lock their reveal and expose no
  external-file-manager setting, so those need a small published Pathem extension,
  not a settings edit; the panel offers to install it rather than claim a config
  edit that can't work. **Sublime Text + TextMate done (2026-07-23):**
  `SublimeIntegration` writes a plugin + sidebar/context/palette entries into a
  Pathem-owned `Packages/Pathem/`; `TextMateIntegration` writes a `Pathem.tmbundle`
  with a "Reveal in Pathem" command. Both write only into a folder Pathem fully
  owns (never merging into the user's files, so Remove is a clean delete) and drive
  the app through `pathem://reveal` (no PATH/CLI dependency). A generic
  `EditorIntegration` registry drives Settings ▸ Integrations -- one Integrate /
  Remove / Preview row per installed editor, with a "restart the editor" nudge; both
  install/remove paths are smoke-checked. **JetBrains done (2026-07-25):** it turned
  out to be an owned-file case too -- JetBrains reads every `tools/*.xml` as its own
  External Tools group, so `JetBrainsIntegration` writes a `tools/Pathem.xml` group
  into each installed IDE profile (IntelliJ/PyCharm/WebStorm/GoLand/… and Android
  Studio), never touching the user's `External Tools.xml`; the tool runs `pathem-cli
  reveal "$FilePath$"` (quoted, so the tested CLI does the encoding). Install/remove/
  preview drive every profile at once; smoke-checked incl. XML well-formedness.
  **Remaining:** VS Code / Cursor, which lock their reveal and expose no
  external-file-manager setting -- so they need a *published* Pathem extension, not a
  config write (the only editor that genuinely can't be done this way).

## Round 14 (shipped 2026-07-26) -- dialog buttons no longer clip the window border

Live-app report: some window prompts had their button row clipped by the window
border when there wasn't enough room. Root cause: several custom NSPanel dialogs
used a hardcoded content height sized for English, so a longer localized string
(wrapping to more lines) or a larger system font pushed the bottom button row past
the fixed window height.

- **Systematic fix, not per-dialog patching.** New `NSWindow.growToFitContent()`
  (in `NSWindow+Centering.swift`) grows a window to its content view's Auto Layout
  fitting size, never shrinking below the designed size (so scroll-view heights stay
  intact). Called just before centering/showing, once content is populated, in every
  custom dialog: Commit, Undo History, Templates, Bulk Attributes, Batch Rename,
  Xattr, ACL editor, Archive contents, and both Automation Rules panels.
  (`InfoInspectorController` already sized to fit; it's the pattern this generalizes.)
- Guarded by a new `PATHEM_SMOKE` invariant, `dialog-grows-to-fit-content`, that
  drives the helper on a deliberately-too-short window and asserts it grows in height
  while preserving the designed width.

## Round 13 (shipped 2026-07-26) -- visible update button + in-app changelog

Two live-app requests: make a pending update visible in the app itself (not just a
background prompt), and keep a changelog in the app without forcing release notes on
anyone.

- **Title-bar "Update Ready" button.** `UpdaterController` now adopts Sparkle's
  gentle-reminder pattern (`SPUStandardUserDriverDelegate`): a scheduled update no
  longer pops an interrupting modal. Instead it flips a `pendingUpdateVersion` signal
  and posts `pathemUpdateStateChanged`; a trailing `NSTitlebarAccessoryViewController`
  (`UpdateButtonAccessory`) shows a small accent-tinted "Update Ready" button, hidden
  the rest of the time. Clicking it resumes the deferred session, opening the installer
  with its release notes. Nothing is forced; the update is just visible and one click
  away. Dormant on unsigned/source builds (no EdDSA key), with a `debugSetPendingUpdate`
  hook so the button is smoke-testable there.
- **In-app changelog (Help > Release Notes).** A bundled `Resources/CHANGELOG.md`
  (authored newest-first) is parsed by a pure, unit-tested `ChangelogParser` in the
  engine and rendered in an on-demand `ChangelogWindowController`. Reachable from a new
  Help menu and the command palette (`help.releaseNotes`); never shown automatically.
- Verified: `swift build`, 704 engine tests (4 new parser tests), and two new
  `PATHEM_SMOKE` invariants (`changelog-bundled-and-parses`,
  `update-button-shows-when-pending`). Six locales reconciled to 0 missing / 0 stale.

## Round 12 (shipped 2026-07-25) -- live previews in column + gallery views

Two live-app reports: the column view's third column and the gallery view's large
preview both showed only a static thumbnail (an enlarged file icon), so gallery
read as "icon view with a preview stuck on top" rather than a real gallery.

- **Live Quick Look in both views.** New shared `QuickLookPreview` (an embedded
  `QLPreviewView` with a graceful icon fallback for folders, online-only/dataless
  items, and anything with no generator). It replaces the `NSImageView` +
  `ThumbnailProvider` static thumbnail in the column view's preview column and the
  gallery view's big preview, so both now render real file content -- scrollable
  PDFs, playable audio/video (not auto-started), selectable text/code, images --
  for the many types Quick Look handles. Dataless items still fall back to the icon
  so previewing never forces an iCloud download. Same proven embedding the docked
  `DocumentPreviewView` pane already uses. The column preview keeps its name +
  kind/size/dates metadata grid under the preview well (now corner-clipped).
- Note: single-click-to-open and hover-underline preferences already shipped
  (Settings > Layout; see the Track A status block) -- single-click in every view,
  hover-underline in list/icon/gallery.

## Round 11 (shipped 2026-07-22) -- transfer progress, inline naming, localization close-out

Three live-app issues plus the Track C close-out.

- **Live transfer progress.** `FileManager.copyItem`/`moveItem` are opaque -- a big
  single-file or cross-volume move sat at 0% then jumped to 100%, with no speed or
  ETA. New `ProgressiveCopy` (built on BSD `copyfile(3)`, the same primitive
  Foundation uses) streams the copy with a cumulative-byte callback and mid-file
  cancel, preserving mode/xattrs/ACLs/resource forks. `FileOperations.copy` and the
  cross-volume branch of `move` now report bytes as they flow, so the existing
  transfer sheet's bar/speed/ETA animate; same-volume moves stay an instant rename.
  Six engine tests (streaming, mid-file cancel + partial cleanup, mode, recursive
  tree, same-volume detection).
- **Inline naming in the icon grid.** A new folder in the icon view is now named
  in place (Finder-style editable label, base name selected), instead of dropping a
  prompt. Commit/cancel mirror the list view; a background reload cancels a
  half-typed edit. The gallery/column/tree/remote views keep the (now-fixed) sheet.
- **Name prompts no longer clip long names.** The shared rename/name sheet sizes its
  field to the filename and keeps a long name in the editable field, not the sheet
  title.
- **Track C closed.** All six catalogs reconciled to 0 missing / 0 stale (1488
  keys); the pre-commit `l10n-lint` hook guards it.

Known: `DirectoryWatcherTests.firesWhenAFileIsCreated` (a live FSEvents timing test)
is flaky/failing on this machine under load -- reproduces on clean HEAD, unrelated
to this round; the pure-logic `pathAffectsListing` sibling passes and the app's live
watching works.

## Round 10 (shipped 2026-07-21) -- PDF markup, caching, and reactive polish

A long session of user-reported bugs and feature requests, all shipped, tested,
and installed. Not launch-runway tracks; a batch of feature depth + fixes.

- **Preview-style PDF markup.** `PDFMarkupView`: highlight/underline/strikethrough
  over a text selection, freehand ink, a drawn signature, rectangle/oval/line/
  arrow, a text box, and sticky notes -- all savable back into the PDF, undoable,
  with a Markup toolbar + color well. Form-filling comes free from PDFKit. Fixed
  three latent bugs found while building it: a blank-page render (document set
  before the view had a frame), ink drawn off-page (the path must be bounds-local),
  and a save lifecycle that could silently drop edits or pop a modal mid-navigation.
- **Default-app viewer.** Declared PDF + image types; opening one from Finder now
  presents the built-in viewer instead of only revealing it.
- **Persistent folder-size cache** (`FolderSizeCache`, folder-sizes.json), keyed by
  folder mtime, so calculate-all-sizes reuses a size across visits and restarts
  instead of re-walking the whole subtree every time.
- **Match Finder Settings** (Pathem menu / palette): reads the user's Finder prefs
  and applies the ones Pathem mirrors -- show hidden files, keep folders on top (a
  new `foldersFirst` pref), and the default view.
- **Sidebar depth.** Track the current folder like Finder/Music; Remove from
  Sidebar for auto-detected system items (hide a stale cloud mount, e.g. a
  signed-out Google Drive) + Restore Hidden Items; Open in New Tab / Other Pane on
  any location; Empty Trash from the Trash background + the sidebar Trash item.
- **Watcher flood fix.** An FSEvents stream is recursive, so a pane on a busy tree
  (worst case `/`) reloaded several times a second on unrelated system activity --
  the "toolbar flashes while backgrounded" report. It now reloads only on
  direct-entry changes. Diagnosed with a new opt-in reload trace
  (`PATHEM_DEBUG_RELOADS` / `~/.pathem-debug-reloads`).
- **Drag + session fixes.** Folders drag to Finder as a file URL (a folder promise
  landed a truncated stub); automation launches (smoke / screenshots / renders)
  never persist over the real session (the "reopens on /tmp tabs" bug).
- **Smaller wins.** Open in This Pane + type-aware quick-bar view buttons; Duplicate
  Tab; Reveal in Pathem hidden where redundant; a status-bar eye toggle for hidden
  files; a rounded sidebar top; the empty-space right-drag gesture trail; a
  deterministic fix for the flaky `cell-accessibility` smoke check.

## Current state

The hard part is done and verified in source: getattrlistbulk fast enumeration
(Gate A virtualizes 1M rows), an FSEvents watcher, dual-pane + tabs + a
Finder-style sidebar, per-folder saved views + apply-to-subfolders, Layouts, a
command registry + rebindable keymap + command palette, on-device semantic
search + an AI command bar, Quick Look, batch rename, preferences, and
copy/move/cut/paste with undo. Universal .app packaging. Clean build, 519 engine
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

## Round 4 (shipped 2026-07-08) -- new views

All four shipped:

- **Tree / outline view** -- SHIPPED. `TreeOutlineController` (a `PaneContentView`
  over NSOutlineView, new `ViewMode.tree`, fifth view-switcher segment, Cmd-5):
  expandable folders with lazy child loading and location-aware selection so file
  ops resolve to the real path.
- **Flat / recursive view** -- SHIPPED. View ▸ Flatten Folder lists every item under
  the folder in one location-aware smart-result view, via `FlatEnumerator`.
- **Commander mode** -- SHIPPED. `CommanderBar` (View ▸ Commander Mode): a bottom
  strip with a folder prompt, a command line that runs in the embedded terminal
  (`TerminalController.runInline`), and F3-F8 buttons mapped to existing commands.
- **Save named view presets** -- SHIPPED. `ViewPreset` model + Save Current View
  As… + a Saved Views menu; each preset is also a "View: name" command.

Custom, plugin-*rendered* views still wait on the gated Swift extension runtime;
named presets are the config-level version of the same idea.

## Round 5 (shipped 2026-07-09) -- site-manager depth + power-user polish

The remote/site-manager cluster and the last power-user affordances. All shipped,
committed, and installed.

- **Site manager Tier 2** -- SHIPPED. Each saved connection gains an optional
  **color label** (a dot in the sidebar Connections section) and a **default local
  directory**, so connecting can open the paired local folder in the other pane.
  Forward-compatible decode (older `connections.json` still loads).
- **Discoverable S3-compatible backends** -- SHIPPED. The S3 backend already spoke
  path-style + SigV4 to any host; the connection editor now has an endpoint picker
  (Amazon, Backblaze B2, Google Cloud Storage, Wasabi, DigitalOcean Spaces,
  Cloudflare R2) that fills the host, so those providers are reachable without hand-
  typing an endpoint. `S3Provider.host` + `S3ProviderTests`.
- **Remote path bookmarks** -- SHIPPED. Bookmark the current remote folder under a
  name (stored on the connection in `connections.json`), then jump back to it from a
  new **Bookmarks** menu. The jump reuses the live session password, so there is no
  re-prompt. `RemoteBookmark` model (round-trip + backward-compat tested).
- **Filter the Connections list** -- SHIPPED. A search field narrows the site list by
  name, host, user, or protocol; row actions map back to the underlying site by
  identity, so filtering never edits the wrong one, and editing keeps bookmarks.
- **Open With Pathem + a Service** -- SHIPPED. A `CFBundleDocumentTypes` folder
  handler (rank Alternate, so Finder stays the default) plus an "Open in Pathem"
  Service and `application(_:open:)`, so folders can be opened into a pane from
  outside the app.
- **Vim-style navigation** -- SHIPPED. An optional mode where `hjkl`, `gg`/`G`, and
  `/` drive selection and search without the mouse (text-field editing is exempt).
- **In-app image Markup** -- SHIPPED. Freehand annotation of an image in a sheet,
  saved back through the normal write + undo path.
- **Custom file/folder icon** -- SHIPPED. Set or remove a custom icon on any file or
  folder from Get Info, via `NSWorkspace.setIcon`.
- **Azure Blob Storage** -- SHIPPED (Round 6). A new `.azure` backend (`AzureBlobProvider`),
  run out-of-process via curl. curl has no built-in Azure signing (unlike S3's
  `--aws-sigv4`), so requests are signed here with `AzureSharedKey` (HMAC-SHA256 over the
  canonicalized request, sent as an Authorization header; only the signature, never the
  key, reaches the argument list). User = storage account, password = account key, host
  blank -> `<account>.blob.core.windows.net`. The signer (checked against an RFC 4231
  vector), the list parser, and derivation are unit-tested (15 tests).
- **Synchronized (delta) browsing** -- SHIPPED (Round 6). Upgraded from a same-path lock
  to relative mirroring, so two different roots track in step. `SyncBrowse.mirroredPath`
  (9 tests).

*Deferred, with reasons:* **formal site groups** -- the per-site color label already
clusters sites visually and the filter covers find, so a full group model is low return;
plugin-*rendered* custom views (gated Swift extension runtime); a signed `SMAppService`
privileged helper (only needed to avoid the terminal `sudo` route for chown). (Cloud
folder badges, once deferred here, shipped in Round 7.)

## Round 8 (shipped 2026-07-09) -- more customization + Finder handoff + clean uninstall

- **Open folders in Pathem** -- SHIPPED. Settings ▸ General makes Pathem the system default
  handler for `public.folder` (reversible; restores Finder). Redirects "open this folder";
  cannot catch "Reveal in Finder" (no OS hook). `FolderHandler`.
- **Reset Pathem Data (clean uninstall)** -- SHIPPED. Pathem menu ▸ Reset Pathem Data: restores
  Finder as the folder default, and (unless you tick "keep my data") removes the app-support
  config, user defaults, and Keychain passwords, then quits with a note on finishing the
  uninstall (Trash the app; clear Full Disk Access). Files are never touched.
- **Default view & sort** -- SHIPPED. A global view mode + sort for folders with no saved view.
- **Commander F-keys** -- SHIPPED. Reassign each F3–F8 slot to any command.
- **Status bar contents** -- SHIPPED. Toggle item count / size / free disk space.
- **New-item + tab options** -- SHIPPED. Default New Folder/File names; new tab after-current or
  at-end.
- **Fixes** -- SHIPPED. Dragging out of a search/smart-result view (per-entry locations), and a
  clear "Spotlight indexing is off" message when smart folders come back empty for that reason.

## Round 9 (shipped 2026-07-09) -- native Swift torrent client

A full torrent system, built as our own native Swift engine rather than bundling a
foreign binary (matching the Swift-only ethos of the AFC client). The engine is
`TorrentKit`; the network/peer code runs out-of-process in `pathem-torrentd`, so it
stays out of the Full-Disk-Access app, consistent with the AFC and extension model.

- **Engine (`TorrentKit`, unit-tested)** -- SHIPPED. Bencode + `.torrent` metadata +
  magnet; HTTP tracker client (announce, compact/dict peers); peer wire protocol
  (handshake + message framing); piece manager with SHA-1 verification and
  reset-on-mismatch; file layout + sparse storage with a path-traversal guard; peer
  connections over Network.framework; and the per-torrent download `TorrentSession`
  (announce -> connect -> pipelined block requests -> verify -> write -> seed state).
- **Daemon + persistence** -- SHIPPED. `TorrentEngine` owns every torrent and
  persists resume state (the `.torrent` files plus completed pieces); `pathem-torrentd`
  drives it over a line-delimited JSON control protocol and restores/resumes on launch.
- **Torrents panel** -- SHIPPED. Tools > Torrents (also toolbar + palette): a live list
  (name, size, themed progress bar, rate, peers, status) driven by the daemon's ~1 Hz
  broadcasts. Add a `.torrent`, pause/resume, remove (keep or delete files), reveal in
  Finder. Bundled + codesigned by `package.sh`; verified end to end by
  `PATHEM_TORRENTS_SMOKE`.
- **Magnet links** -- SHIPPED. Paste a magnet (Tools > Torrents > Add Magnet, clipboard
  pre-filled): the engine parses the URI (hex or base32 info hash), announces to its
  trackers for peers, fetches the info dictionary over ut_metadata (BEP 9 / BEP 10),
  verifies it against the info hash, then downloads normally. Magnet, extended-message,
  and metadata-assembly logic is unit-tested; the daemon shows a magnet as "checking"
  until its metadata resolves.
- **Seeding** -- SHIPPED. Peer connections are bidirectional: we serve blocks peers request
  from storage (counting an upload rate, shown in a new "Up" column), broadcast `have` as
  pieces finish, and a `PeerListener` accepts incoming peers so peers can dial us, not just
  us them. Proven by a loopback end-to-end test: a real leecher downloads a file from a real
  seeder over TCP and verifies it byte-for-byte -- the first test that transfers actual bytes
  through the whole stack (listener, handshake, request pipeline, serving, verification, storage).
- **DHT (BEP 5)** -- SHIPPED. A lookup-only mainline DHT node: 160-bit ids + XOR distance, the
  KRPC codec (ping / find_node / get_peers / announce_peer), and a UDP client that bootstraps
  from the well-known routers and iteratively queries the closest nodes for peers. The session
  runs it whenever peers are scarce (skipping private torrents), so a trackerless magnet finds
  peers. The codec is unit-tested; a gated live test (PATHEM_DHT_LIVE=1) confirms it finds real
  peers for a well-seeded torrent against the actual network.
- **NAT-PMP port mapping (RFC 6886)** -- SHIPPED. When the listener starts, the engine finds the
  default gateway and asks it to forward our TCP port, renewing before the lease expires, so peers
  behind common home-router NAT can reach us. Best-effort: routers without NAT-PMP just don't
  answer, and outbound connections work regardless. Codec unit-tested; gateway detection verified.
- **Torrent creation** -- SHIPPED. Right-click a file or folder > Create Torrent: TorrentCreator
  walks the content, auto-picks a piece length, SHA-1s the pieces (spanning file boundaries), and
  writes standard bencoded metadata (optional tracker, private flag, skips .DS_Store). Hashing
  runs off the main thread. Output round-trips through the parser with a correct info hash, proven
  by a test that verifies every created piece hash against the real bytes.
- **Native .torrent / magnet handling** -- SHIPPED. Opening a .torrent (in a pane or from Finder)
  or a magnet: URL adds it straight to the Torrents panel; context-menu Add to Torrents / Copy
  Magnet Link for .torrent selections; Info.plist registers the document type + magnet: scheme.
  The old one-shot inspector plugin was removed as redundant.
- **Per-file selection** -- SHIPPED. Download only some files of a multi-file torrent: the piece
  manager honours a "wanted" set (FileLayout maps selected files to the pieces they overlap,
  including straddling pieces), so unwanted pieces are never requested and "complete" means every
  wanted piece is done. Torrents > Files opens a checkbox list; the selection applies live and
  persists. Wanted-set and file-to-piece mapping are unit-tested; the daemon files/setFiles round
  trip is verified.
- **MSE/PE encryption** -- SHIPPED. Message Stream Encryption on outgoing connections: a native
  768-bit Diffie-Hellman (a purpose-built BigUInt with Knuth-D long division, ~80x faster than
  naive modexp) + RC4, then the obfuscated handshake (hash-sync, crypto negotiation). Verified end
  to end: an initiator/responder loopback agrees on the ciphers, and a real encrypted TCP socket
  exchanges a wire message that decrypts correctly. A "prefer encryption" toggle tries MSE and
  falls back to plaintext. Crypto + handshake unit-tested.
- **Peer exchange, DHT, NAT-PMP/UPnP, web seeds, super-seed** -- SHIPPED (see above).
- **Speed limits** -- SHIPPED. Global download / upload caps via a token-bucket RateLimiter
  (injectable clock, unit-tested): the session paces its request pipeline and its block serving
  through the shared limiters, so throttling the ask throttles receipt. Set from Torrents > Speed
  Limits (KB/s, 0 = unlimited), sent over the control protocol, applied live, and persisted.
- **Peer exchange (BEP 11, ut_pex)** -- SHIPPED (receive side). Outgoing peers advertise ut_pex
  over the extension protocol, and the peers others share in their `added` field are fed straight
  into the session, so a healthy swarm keeps topping up peers without more tracker/DHT traffic.
  Codec unit-tested; sending our own PEX deltas is a good-citizen follow-up.
- **uTP transport (BEP 29)** -- SHIPPED (core). The uTP packet codec (20-byte header + extension
  skipping) and a reliable connection: SYN handshake, sequence numbers, cumulative acks, reorder
  buffering, and timeout retransmission. Verified with a lossy in-memory channel - an 8 KB transfer
  arrives complete and in order, and recovers from 1-in-4 packet loss. Full LEDBAT delay-based
  congestion control (currently a fixed window) and swapping it under PeerConnection as a transport
  option are the remaining refinements.
- **Honest boundary / next up.** `.torrent` and magnet downloads, seeding (with NAT-PMP so inbound
  peers can reach us), and peer discovery via trackers + DHT + PEX all work today. Not yet at full
  standalone-client parity: no UPnP-IGD fallback for routers that speak only UPnP; the DHT is
  lookup-only (doesn't serve queries or keep a persistent routing table); PEX is receive-only; and
  no uTP or encryption. Nearest-value follow-ups: send-side PEX, a persistent DHT routing table,
  then UPnP-IGD.

## Round 7 (shipped 2026-07-09) -- deep customization + a layout fix

A "make everything customizable" pass (Directory-Opus-class), plus one important fix.

- **Fix: blank panes** -- SHIPPED. The tab-bar and the pane's top toolbar stack views
  weren't hugging their height, so they stretched and squeezed the file list to zero
  height: panes showed correct item counts but no rows. Both now hug vertically; a new
  `pane-content-not-squished` smoke check (asserts real list height) guards the class of
  bug the old checks missed (they only looked at data + pane width).
- **Cloud folder badges** -- SHIPPED. Cloud folders carry a small service badge (iCloud,
  Dropbox, Google Drive, OneDrive, Box) so same-named folders across services read apart.
  Pure path->service detection (`CloudLocation`, 8 tests) covers `~/Library/CloudStorage`
  providers, iCloud Drive, and legacy `~/Dropbox` / `~/Google Drive`; a tinted-cloud
  compositor badges list / icon / column / tree.
- **Sidebar sections** -- SHIPPED. Drag any section (built-in header or user group) to
  reorder it among the others; the order persists (`Sidebar.orderedKeys`, tested) and a
  newly appearing section still shows. Also merged the redundant "Smart" and "Smart
  Folders" headers into one.
- **Context-menu editor** -- SHIPPED. Settings > Menus is now a reorderable list: drag to
  reorder the file right-click menu, uncheck to hide, Reset to Default. Data-driven from a
  saved order (`ContextMenuLayout`, tested); separators auto-insert between groups and a
  tidy pass hides any left dangling by conditional items.
- **File color rules (labels)** -- SHIPPED. Settings > Labels: color/style filenames by
  rules (extension, name contains/begins/ends/glob, size, folder-vs-file) with color +
  bold/italic; first enabled match wins. Engine `ColorRule`/`ColorRules` + a glob matcher
  (7 tests); a shared `FileColorStyle` colors list / icon / column / tree.
- **Size & date formats** -- SHIPPED. Decimal (KB/MB) vs binary (KiB/MiB) sizes; relative
  / short / medium dates.
- **Startup & open behavior** -- SHIPPED. New tabs/windows open to the last folder, Home,
  or a fixed folder; middle-click opens a folder in a new tab.
- **Custom toolbar buttons** -- SHIPPED. The Customize Toolbar palette now exposes every
  registered command -- saved external commands (a bolt icon) and any other registry
  command -- not just the curated catalog, so anything can go on the toolbar.
- **Copy Path + navigation menus** -- SHIPPED. Copy Path from a sidebar item; a
  folder-level right-click menu on empty pane space (Copy Path/Name of the current folder,
  New Folder/File/Paste); and a context menu on breadcrumb segments *and* tabs (open that
  folder in a new tab or the left/right pane, copy its path).

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
- Torrents: SHIPPED as a native Swift engine (see Round 9), not a libtorrent bundle.
  Remaining for standalone-client parity: magnet metadata exchange, seeding, DHT.

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

Tier 2 (organization and power): mostly SHIPPED (Round 5).

- **Search** in the site list -- SHIPPED (filter by name/host/user/protocol).
  *Formal groups* deferred (color labels already cluster sites; see Round 5).
- **Per-site color labels** -- SHIPPED.
- **Per-site default local directory** -- SHIPPED. **Synchronized browsing** (both
  panes move together) -- SHIPPED (View ▸ Sync Browsing): relative/delta mirroring, so
  two different roots track in step, not just a same-path lock. `SyncBrowse.mirroredPath`.
- **Bookmarks** -- SHIPPED (saved remote paths per site, via the Bookmarks menu).

Tier 3 (breadth and niceties):

- More cloud backends: **Backblaze B2, Google Cloud Storage** and other S3-compatible
  endpoints -- SHIPPED (Round 5, endpoint picker). **Azure Blob** -- SHIPPED (Round 6):
  its own Shared Key (HMAC-SHA256) signer, since it isn't S3-compatible.
- FTP **passive / active** mode and charset / encoding.
- Per-site speed limits, keep-alive / reconnect, SOCKS / HTTP proxy.

## Recently requested (in flight / backlog, 2026-07-05)

- **Undo history + selective undo** -- SHIPPED (2026-07-08). See "Next up".
- **Easy folder-icon change from folder properties** (Get Info) -- SHIPPED (Round 5).
- **Cloud folder badges** -- SHIPPED (Round 7). The real folder icon is kept and a small
  tinted service badge (iCloud, Dropbox, Google Drive, OneDrive, Box) is composited in the
  corner across list / icon / column / tree. Tinted SF Symbol clouds rather than bundled
  brand logos (no trademark concerns), distinguished by color.
- **Super-drag follow-ups:** the flick-to-command map is user-editable (Settings ▸ Gestures)
  and the gesture works in list / icon / gallery / column. Only the tree outline lacks it
  (hierarchical; a flick reads oddly there), which is the sole remaining gap.

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
