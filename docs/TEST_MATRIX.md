# Test coverage matrix

Pathem uses three complementary layers. `make test` covers engines and protocols in process;
`make e2e` launches the debug product as separate processes and is the product-level CI gate;
`make e2e-app` assembles, signs, and externally launches the release app. A green row means the
named behavior is exercised at that layer, not that every permutation of the feature is covered.
`make e2e-env` separately reports environmental boundaries as PASS/SKIP/FAIL; absent hardware or
permission is never counted as a pass. See [ENVIRONMENTAL_TESTING.md](ENVIRONMENTAL_TESTING.md).

| Feature area | Unit / integration (`make test`) | Product E2E (`make e2e`) | Release package (`make e2e-app`) | Remaining boundary |
|---|---|---|---|---|
| Launch, panes, layout | Models and layout rules | Real app, window and pane invariants | Real signed binary stays alive and exposes an on-screen layer-0 window to an external Core Graphics probe | External AX-tree probe exists; current host lacks Accessibility permission. Full exploratory and assistive-technology sign-off remains human |
| Million-row list | Enumerators and file columns | Real `NSTableView`, 1,000,000 rows, bounded materialized cells | Bundle/launch only | Real 25,000-file enumeration passes; older-Mac performance remains a manual workflow |
| Core file operations | Create, copy, move, trash, links, conflicts, undo-related models | Real-file create/rename; skip and verified replace-copy; keep-both move; pre-mutation cancel; undo/redo; Trash/Put Back; batch create; swap-safe batch rename; symlink/hardlink/alias resolution; plus 37 always-on and 11 real-iCloud on-screen checks | Bundle/launch only | Disposable APFS cross-volume move, disk-image attach/eject, and a truly evicted online-only iCloud move all pass; physical removable storage and destructive confirmation sheets remain environmental |
| Navigation and views | Navigation, saved formats, filters, columns, sidebar, keymap | Real-window list/icon/gallery/column/tree interactions; generated matrix proves all 29 effective shortcuts and all nine drop destinations are wired | Bundle/launch only | Human drag semantics across third-party apps |
| Search, metadata, media | Content/semantic/Spotlight search, hashing, tags, metadata, image transforms | Real-file literal/extended-regex search and replace with binary exclusion; Finder tag/comment set-and-clear and hash round-trips; AI path runs or honestly skips | Bundle/launch only | Disposable live Spotlight import/query passes; Apple Intelligence and large user libraries vary by machine |
| File-search UI | Literal filename versus content fixtures, recursion/scope isolation, streaming boundaries, symlink exclusion, limits/errors and Spotlight predicate construction | Mandatory `PATHEM_FILE_SEARCH_TEST`: 465 real-window checks, all five views/both panes with nonzero viewports and accepted-listing receipts, toolbar/Cmd-F and field-editor typing, scope/mode controls, Return/keypad Enter Reveal, exact Open callback, stale response/reopen/navigation controls and minimum-window geometry; isolated temporary config required | Bundle/launch only | Whole-Mac routing uses a fixture backend; live index completeness, native visual/picker approval, physical input and default-app opening remain environmental. See [SEARCH_INTERACTION_MATRIX.md](SEARCH_INTERACTION_MATRIX.md) |
| Archives and disk utilities | Archive list/repack, split, disk-image and secure-delete logic | ZIP create/list/extract/edit/repack, cross-folder staging, native 7-Zip round-trip, and corrupt-input failure; split/merge; backup; secure delete; encrypted DMG creation | Bundle/launch only | Environmental runner proves attach/eject; privileged/destructive OS confirmation dialogs stay manual |
| Git and developer tools | Status/ops integration, terminal-adjacent commands, external commands | Real repo init/status/stage/diff/commit and clean-tree commit failure; external command; terminal launch in smoke | Bundle/launch only | Environmental runner proves interactive-shell substrate and arbitrary tool invocation; third-party tool-specific behavior remains external |
| Remote/cloud | S3, Azure, WebDAV, FTP and SFTP parsers/signing/security; runner IPC | Full HTTPS S3/Azure and HTTP WebDAV CRUD plus 404 propagation through system curl against hermetic loopback services; fixtures cryptographically validate AWS SigV4/Azure Shared Key and reject invalid signatures | Helpers are present and signed | Loopback FTP/SFTP CRUD and read-only NFS enumeration pass; public-service TLS/credentials remain external |
| Analysis, sync, attributes | Duplicate, size, compare/sync, and bulk-attribute engines | Real files prove full-content duplicate grouping, recursive size/symlink behavior, additive two-way sync with skipped conflicts, and batch date/mode/tag mutation | Bundle/launch only | Real 25,000-file tree and mounted-provider bulk/Foundation parity pass; larger user datasets remain environmental |
| iOS devices | AFC, usbmux and lockdown protocol logic | No hardware dependency in CI | AFC helper is present and signed | Runner reports physical-device presence honestly; trust/pairing needs attached hardware |
| Localization | String behavior and lint | Six catalogs bundled and resolve in the app | Six catalogs packaged | Human translation quality review |
| Torrents: `.torrent` | Parse, storage, trackers, peer wire, verification, pause/resume/remove, real TCP seed/leecher | Real app → daemon IPC adds, lists files and details, changes file selection and limits, pauses, restarts/restores, resumes, and removes a `.torrent` | Torrent daemon is present and signed | Opt-in gate proves Pathem downloads verified bytes from Transmission; public swarm availability still varies |
| Torrents: magnet links | Parse + BEP 9; hermetic local HTTP tracker and real TCP peer resolve metadata, download pieces, verify bytes | Real app → daemon IPC adds a magnet, observes its pending state, and surfaces an invalid-magnet error | Torrent daemon is present and signed | Opt-in `PATHEM_MAGNET_LIVE=1` (2026-11-16): a public magnet for Debian 13.7.0 netinst, with tracker only, resolved metadata from a peer in 50 s and downloaded 792,723,456 bytes matching Debian's SHA-256 in 93 s total; it depends on the swarm and is not in CI. Magnet `ws=` web seeds are not read, so a magnet whose only source is a web seed (Internet Archive items) never starts |
| Torrent discovery/security | DHT server logic, PEX, NAT-PMP, UPnP, MSE, VPN kill switch, rate limits, experimental µTP | Daemon process boundary is exercised | Helper presence/signature | Live public DHT and NAT-PMP pass on this host; third-party µTP remains unproven |

## Commands and CI policy

The sidebar-transfer regression (`PATHEM_SIDEBAR_TRANSFER_UI_TEST`) additionally
dispatches native sidebar Paste actions against real temporary files, checks cut
versus copy and undo, and delivers private drag pasteboards/modifier events through
sidebar/breadcrumb/Up delegates. Both drag defaults, Command inversion, copy-only
sources and unsupported-operation refusal are distinct controls. See
[SIDEBAR_TRANSFER_TESTING.md](SIDEBAR_TRANSFER_TESTING.md) for the causal contract;
this does not claim physical dragging in third-party apps or provider hydration.
The same mandatory scenario includes 88 sidebar/file-safety regression checks:
created-item restore collisions, selective-undo ancestor dependencies, real
partial/skipped/failed cut-paste and retry, newer clipboard/Cut ownership, and
engine-cancellation bookkeeping. Engine tests additionally cover dependent
Replace Undo/Redo identity and failed-Redo rollback. See
[FILE_SAFETY_TESTING.md](FILE_SAFETY_TESTING.md) for red/green evidence and boundaries.
It now additionally runs 90 operation-stability checks (178 total): real prompt
ownership/Cancel/batch controls, private-pasteboard admission, nonzero passive
refresh and rename viewports across all five views, late inline-edit deferral,
ordinary versus Option file drops, and opt-in Downloads queues, shared claims,
Dismiss All, mounted controls and a real disposable-folder watcher. See
[MOVE_PROMPT_AUDIT.md](MOVE_PROMPT_AUDIT.md) for red baselines, counterfactuals and
limits; these do not close the independent intermittent lifecycle tasks.
The separate 49-check UI interaction suite also protects the table-header inset
at the top of a passive metadata refresh (`-28` remains `-28`) and uses a private
clipboard for its Cut/Paste fixtures rather than replacing the owner's clipboard.

- `make ci` runs localization lint, a full serial engine test pass, the complete debug product E2E
  suite, and the release-package gate. GitHub Actions runs the same layers.
- `make e2e-app` is the release-bundle gate. Launch liveness, an externally observed visible window,
  bundle contents, languages, helpers, and signature are all mandatory; the read-only window probe
  needs no Accessibility permission.
- `make e2e-env` creates credential-free loopback FTP/SFTP fixtures. Its documented environment
  variables opt into Spotlight, provider, DHT, router, Transmission and attached-hardware checks.

No suite honestly covers “all features” end to end: hardware, public services, router behavior,
OS permission sheets, Spotlight timing, and third-party interoperability cannot be hermetic CI
assertions. Every deterministic local feature family now has a mandatory product-boundary scenario;
the matrix keeps the remaining environmental boundaries explicit.
