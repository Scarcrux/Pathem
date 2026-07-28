# Launch checklist (Track D: the public flip)

This is the go/no-go checklist for making the repository public and turning the
site into a live funnel. It is deliberately about **decisions and verification**,
not build mechanics: the notarize / sign / Sparkle / appcast runbook lives in
**[RELEASE.md](RELEASE.md)** and is not repeated here.

The repo is intentionally private until the gate below is met. Nothing on the
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
- [ ] **No P0/P1 open** in whatever issue list you keep. Known-minor is fine;
      write them down so launch-day reports can be triaged against them.
- [ ] **`swift test` green**, `PATHEM_SMOKE=1` reports `RESULT: PASS`, and the
      l10n lint (`python3 scripts/l10n_lint.py`) exits 0.

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
      regression path) — the second drag must still work.
- [ ] Switch the system language to one of the five non-English locales and spot
      check that the menus/sidebar/dialogs are translated (coverage is linted, but
      look for layout truncation).
- [ ] Sparkle: with a prior version installed, confirm "Check for Updates"
      offers and applies the new build (needs the appcast published per RELEASE.md).

## 3. Docs & repo hygiene (before it's public)

- [ ] **README** reads well to a stranger: what it is, the honest state, a
      screenshot, build-from-source steps, and the download story (see §5).
- [ ] **LICENSE** present and correct.
- [ ] **SECURITY.md** has a real disclosure contact.
- [ ] No secrets, tokens, absolute local paths, or private notes in the tree or
      git history. `git log` authorship is uniform.
- [ ] `.github/workflows/release.yml` secrets exist (Developer ID cert, notary
      creds, `SPARKLE_PRIVATE_KEY`) if you want tag-triggered releases.
- [ ] Optional: to publish the VS Code / Cursor extension, set `VSCE_PAT`
      (and `OVSX_PAT`) and push a `vscode-v<version>` tag
      (`.github/workflows/vscode-extension-release.yml`). Without the tokens the
      tag still builds the `.vsix` and attaches it to a GitHub Release.
- [ ] Scrub for stray iCloud conflicted-copy files (`* [0-9].*`).

## 4. Cut the first public build

Follow **[RELEASE.md](RELEASE.md)** end to end. Gating summary:

- [ ] One-time: `scripts/setup-sparkle-key.sh` run, `SUPublicEDKey` committed,
      **private key backed up** (losing it means no user can ever update again).
- [ ] Developer ID cert + `notarytool` profile in place.
- [ ] Version bumped in `Packaging/Info.plist` (`CFBundleShortVersionString` +
      an incremented `CFBundleVersion`).
- [ ] `PUBLISH=1 scripts/release.sh` (or push a `v*` tag) produces a **notarized,
      stapled** DMG + a signed `appcast.xml` on the GitHub release.
- [ ] Download the published DMG on a clean Mac and confirm Gatekeeper opens it
      without a warning.

## 5. The flip

- [ ] Wire the site's primary CTA from "Star on GitHub / downloads soon" to the
      **real download link** (the release DMG) + confirm the Sparkle feed URL
      resolves. (Site Track B item B3.)
- [ ] Add the marquee screenshots the site currently only describes — terminal,
      torrents, remote/site-manager. (Track B item B2.)
- [ ] Flip the repository to **public**.
- [ ] Verify the live site: OG card renders when the URL is shared, favicon +
      manifest load, sitemap reachable, all links resolve.

## 6. Immediately after

- [ ] Watch the first issues/discussions; triage against the known-minor list.
- [ ] Confirm auto-update works from the *first* public version to a quick
      follow-up (the real test of the Sparkle chain is the second release).
- [ ] Keep a short changelog going for the appcast release notes.

## Rollback

The repo can go private again, but assume anything published (code, DMG) was
cloned/downloaded the moment it was public — treat the flip as irreversible for
anything sensitive. A bad *build* is recoverable: ship a higher `CFBundleVersion`
fix; Sparkle pulls users forward. There is no un-publishing a leaked secret, so §3
is the load-bearing step.
