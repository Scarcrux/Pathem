# Launch checklist (Track D: the public flip)

This is the go/no-go checklist for making the repository public and turning the
site into a live funnel. It is deliberately about **decisions and verification**,
not build mechanics: the notarize / sign / Sparkle / appcast runbook lives in
**[RELEASE.md](RELEASE.md)** and is not repeated here.

**Status (2026-11-18):** the repository went public and Pathem 0.9.0 was released
on 2026-11-17. Boxes below are ticked only where the evidence is recorded (noted on
the line); unticked boxes are still open, including some the owner may have done
but not recorded. The rest of this file is kept as written.

The repo was intentionally private until the gate below was met. Nothing on the
[ROADMAP](ROADMAP.md) is blocked on the flip; everything here just makes the flip
land well. Work top to bottom: **exit criteria → QA → docs → cut the build →
flip → post-flip**. Draft criteria are proposals; adjust the thresholds, then
treat the boxes as the real gate.

## 1. Exit criteria (the testing gate)

The standing decision is "more user testing before public." Make that concrete so
"ready" is a fact, not a feeling. Proposed bar:

- [ ] **Real-hardware soak:** the dev build has run as the daily file manager on
      at least one Mac for **2+ weeks** with no data-loss incident and no
      unresolved crash.
- [ ] **A second machine / macOS version** has run it for a few days (catches
      per-Mac assumptions: Intel vs Apple Silicon, an older macOS, a different
      accent/appearance, a non-English system language).
- [ ] **The destructive paths are trusted:** trash + Empty Trash, move/copy with
      conflicts, batch rename, secure delete, and undo/redo have each been
      exercised on real files with the outcome verified. No silent data loss.
- [ ] **Full Disk Access onboarding** has been walked by someone who did *not*
      build the app, from a clean state, and it was obvious what to do.
- [x] **No P0/P1 open** in whatever issue list you keep (2026-11-18: none in the
      roadmap; known-minor LM2-F4 and LM2-F6 layout findings; TS-F2 closed as
      intended by owner ruling). Known-minor is fine;
      write them down so launch-day reports can be triaged against them.
- [x] **`swift test` green**, `PATHEM_SMOKE=1` reports `RESULT: PASS`, and the
      l10n lint (`python3 scripts/l10n_lint.py`) exits 0. (2026-11-17: the 0.9.0
      release gate's make ci: 861 unit tests, debug E2E 69 pass with 1 known skip,
      packaged E2E 14/14, l10n lint clean.)

When every box is checked, the gate is open. Everything below is executable in a
day or two.

## 2. Pre-flip QA pass

A focused manual pass on a **release build** (not the dev binary), on a clean
account if possible. The smoke self-check covers invariants; this covers the
things a human has to look at.

- [ ] Launch from `/Applications`, grant Full Disk Access, confirm the pane
      populates and the permission-denied placeholder is gone.
- [ ] Dual-pane copy/move between sides, including a name conflict (Replace /
      Keep Both / Skip), then **undo** it.
- [ ] Rename in place (Return), Get Info, set a custom icon, tag a file, Empty
      Trash from the Trash location.
- [ ] Each view mode (list / icon / gallery / column / tree) renders and switches
      without stranding the panes; the PDF preview pane zooms/prints; Open in
      Other Pane shows a PDF/image.
- [ ] The marquee features that the site will show actually work on this build:
      the embedded terminal, a torrent, and one remote backend (S3/WebDAV/SFTP/FTP).
- [ ] Drag a file **out to Finder and back into Pathem twice** (the drag-strand
      regression path): the second drag must still work.
- [ ] Switch the system language to one of the eleven non-English locales and spot
      check that the menus/sidebar/dialogs are translated (coverage is linted, but
      look for layout truncation).
- [ ] Sparkle: with a prior version installed, confirm "Check for Updates"
      offers and applies the new build (needs the appcast published per RELEASE.md).

## 3. Docs & repo hygiene (before it's public)

- [x] **README** reads well to a stranger: what it is, the honest state, a
      screenshot, build-from-source steps, and the download story (see §5).
- [x] **LICENSE** present and correct (MIT, Copyright Scarcrux LLC).
- [x] **SECURITY.md** has a real disclosure contact (GitHub private vulnerability
      reporting is on; security@pathem.app is listed, but whether it is monitored
      is unconfirmed).
- [x] No secrets, tokens, absolute local paths, or private notes in the tree or
      git history (2026-11-17: make release-safety PASS, 59 history findings
      reviewed and baselined in scripts/release-safety-history-baseline.txt). Run `make release-safety` (runs the discrimination controls first)
      (requires local gitleaks). The gate scans candidate files plus all reachable
      refs and enforces noreply author/committer emails with redacted summaries.
      Pattern checks do not certify all personal identities, addresses, phone
      numbers or private prose: manual review remains required. A failure requires
      private review/credential rotation as applicable, not automatic history edits.
- [x] Not applicable: release.yml is manual-only and releases are cut locally with
      scripts/release.sh (README). Original item: `.github/workflows/release.yml` secrets exist (Developer ID cert, notary
      creds, `SPARKLE_PRIVATE_KEY`) if you want tag-triggered releases.
- [ ] Optional: to publish the VS Code / Cursor extension, set `VSCE_PAT`
      (and `OVSX_PAT`) and push a `vscode-v<version>` tag
      (`.github/workflows/vscode-extension-release.yml`). Without the tokens the
      tag still builds the `.vsix` and attaches it to a GitHub Release.
- [x] Scrub for stray iCloud conflicted-copy files (`* [0-9].*`) (2026-11-18: none
      tracked).

## 4. Cut the first public build

Follow **[RELEASE.md](RELEASE.md)** end to end. Gating summary:

- [x] One-time: `scripts/setup-sparkle-key.sh` run, `SUPublicEDKey` committed
      (verified; the 0.9.0 appcast signature checks against it). **Still confirm the
      private key is backed up** (losing it means no user can ever update again).
- [x] Developer ID cert + `notarytool` profile in place.
- [x] Version bumped in `Packaging/Info.plist` (0.9.0, build 24; the next release
      needs build 25 or higher, enforced by release.sh P8) (`CFBundleShortVersionString` +
      an incremented `CFBundleVersion`).
- [x] `PUBLISH=1 scripts/release.sh` (or push a `v*` tag) produces a **notarized,
      stapled** DMG + a signed `appcast.xml` on the GitHub release.
- [ ] Download the published DMG on a clean Mac and confirm Gatekeeper opens it
      without a warning. (Partly: a signed-out download on the build Mac passed
      Gatekeeper and verify-release; a clean second Mac has not been tried.)

## 5. The flip

- [x] Wire the site's primary CTA from "Star on GitHub / downloads soon" to the
      **real download link** (the release DMG) + confirm the Sparkle feed URL
      resolves. (Site Track B item B3.)
- [x] Add the marquee screenshots the site currently only describes: terminal,
      torrents, remote/site-manager. (Track B item B2.)
- [x] Flip the repository to **public** (2026-11-17).
- [x] Verify the live site (2026-11-17: links, headers and console checked; see
      the roadmap): OG card renders when the URL is shared, favicon +
      manifest load, sitemap reachable, all links resolve.

## 6. Immediately after

- [ ] Watch the first issues/discussions; triage against the known-minor list.
- [ ] Confirm auto-update works from the *first* public version to a quick
      follow-up (the real test of the Sparkle chain is the second release).
- [x] Keep a short changelog going for the appcast release notes (the release body
      is taken from Sources/Pathem/Resources/CHANGELOG.md).

## Rollback

The repo can go private again, but assume anything published (code, DMG) was
cloned/downloaded the moment it was public; treat the flip as irreversible for
anything sensitive. A bad *build* is recoverable: ship a higher `CFBundleVersion`
fix; Sparkle pulls users forward. There is no un-publishing a leaked secret, so §3
is the load-bearing step.
