# Test coverage matrix

Pathem uses three complementary layers. `make test` covers engines and protocols in process;
`make e2e` launches the debug product as separate processes and is the product-level CI gate;
`make e2e-app` assembles, signs, and externally launches the release app. A green row means the
named behavior is exercised at that layer, not that every permutation of the feature is covered.

| Feature area | Unit / integration (`make test`) | Product E2E (`make e2e`) | Release package (`make e2e-app`) | Remaining boundary |
|---|---|---|---|---|
| Launch, panes, layout | Models and layout rules | Real app, window and pane invariants | Real signed binary stays alive and exposes an on-screen layer-0 window to an external Core Graphics probe | Full exploratory UX and assistive-technology pass |
| Million-row list | Enumerators and file columns | Real `NSTableView`, 1,000,000 rows, bounded materialized cells | Bundle/launch only | Performance across older supported Macs |
| Core file operations | Create, copy, move, trash, links, conflicts, undo-related models | Real-file create/rename; skip and verified replace-copy; keep-both move; pre-mutation cancel; undo/redo; Trash/Put Back; batch create; swap-safe batch rename; symlink/hardlink/alias resolution; plus 35 always-on and 11 real-iCloud on-screen checks | Bundle/launch only | Online-only iCloud eviction, removable volumes, network shares, every conflict sheet |
| Navigation and views | Navigation, saved formats, filters, columns, sidebar, keymap | Real-window list/icon/gallery/column and navigation interactions | Bundle/launch only | Every shortcut and drag/drop destination |
| Search, metadata, media | Content/semantic/Spotlight search, hashing, tags, metadata, image transforms | Real-file literal/extended-regex search and replace with binary exclusion; Finder tag/comment set-and-clear and hash round-trips; AI path runs or honestly skips | Bundle/launch only | Apple Intelligence varies by machine; Spotlight indexing and large real libraries |
| Archives and disk utilities | Archive list/repack, split, disk-image and secure-delete logic | ZIP create/list/extract/edit/repack, cross-folder staging, native 7-Zip round-trip, and corrupt-input failure; split/merge; backup; secure delete; encrypted DMG creation | Bundle/launch only | Attach/eject and privileged/destructive OS confirmation dialogs stay manual |
| Git and developer tools | Status/ops integration, terminal-adjacent commands, external commands | Real repo init/status/stage/diff/commit and clean-tree commit failure; external command; terminal launch in smoke | Bundle/launch only | Interactive shell semantics and arbitrary third-party tools |
| Remote/cloud | S3, Azure, WebDAV, FTP and SFTP parsers/signing/security; runner IPC | Full HTTPS S3/Azure and HTTP WebDAV CRUD plus 404 propagation through system curl against hermetic loopback services; fixtures cryptographically validate AWS SigV4/Azure Shared Key and reject invalid signatures | Helpers are present and signed | FTP/SFTP live tests are opt-in; public-service TLS and third-party interoperability remain external |
| Analysis, sync, attributes | Duplicate, size, compare/sync, and bulk-attribute engines | Real files prove full-content duplicate grouping, recursive size/symlink behavior, additive two-way sync with skipped conflicts, and batch date/mode/tag mutation | Bundle/launch only | Very large trees and provider-backed metadata behavior remain environmental |
| iOS devices | AFC, usbmux and lockdown protocol logic | No hardware dependency in CI | AFC helper is present and signed | Physical device trust/pairing is manual |
| Localization | String behavior and lint | Six catalogs bundled and resolve in the app | Six catalogs packaged | Human translation quality review |
| Torrents: `.torrent` | Parse, storage, trackers, peer wire, verification, pause/resume/remove, real TCP seed/leecher | Real app → daemon IPC adds, lists files and details, changes file selection and limits, pauses, restarts/restores, resumes, and removes a `.torrent` | Torrent daemon is present and signed | Third-party swarm interoperability |
| Torrents: magnet links | Parse + BEP 9; hermetic local HTTP tracker and real TCP peer resolve metadata, download pieces, verify bytes | Real app → daemon IPC adds a magnet, observes its pending state, and surfaces an invalid-magnet error | Torrent daemon is present and signed | Public DHT lookup is opt-in; magnet E2E does not depend on the public internet |
| Torrent discovery/security | DHT server logic, PEX, NAT-PMP, UPnP, MSE, VPN kill switch, rate limits, experimental µTP | Daemon process boundary is exercised | Helper presence/signature | Live DHT and router mapping vary by network; third-party µTP remains unproven |

## Commands and CI policy

- `make ci` runs localization lint, a full serial engine test pass, the complete debug product E2E
  suite, and the release-package gate. GitHub Actions runs the same layers.
- `make e2e-app` is the release-bundle gate. Launch liveness, an externally observed visible window,
  bundle contents, languages, helpers, and signature are all mandatory; the read-only window probe
  needs no Accessibility permission.
- `PATHEM_DHT_LIVE=1 make test -- --filter liveDHTFindsPeers` opts into the public mainline DHT.
- Live FTP/SFTP tests require `PATHEM_LIVE_REMOTE=1` plus
  `PATHEM_LIVE_FTP_PASSWORD` and `PATHEM_LIVE_REBEX_PASSWORD`. Missing opt-in requirements appear
  as disabled tests rather than silent passes.

No suite honestly covers “all features” end to end: hardware, public services, router behavior,
OS permission sheets, Spotlight timing, and third-party interoperability cannot be hermetic CI
assertions. Every deterministic local feature family now has a mandatory product-boundary scenario;
the matrix keeps the remaining environmental boundaries explicit.
