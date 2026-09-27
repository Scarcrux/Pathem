# What's left before public

A focused readout of where Pathem stands after the six-person committee audit and
the remediation that followed. The go/no-go mechanics for the flip itself live in
**[../LAUNCH_CHECKLIST.md](../LAUNCH_CHECKLIST.md)**; this page is about what is
*done* versus what still needs a person.

## The audit is fully remediated

Every dimension the committee flagged has been fixed, tested, and shipped. Nothing
below is a known open defect.

| Dimension | Verdict | What shipped |
|---|---|---|
| **Correctness** | No P0/P1 found | Silent-partial-success paths now report honestly: intra-batch name collisions prompt, the metadata editor surfaces per-item failures, a failed Replace says where the file went, batch rename never lies about "kept as X". |
| **Scale** | Render already earned the 1M claim | The two O(total-entries) folder-open side-passes are gone: tag dots read lazily for the visible window, the semantic index builds on first search (not every navigation). DuplicateFinder gained a head-block prefilter. |
| **Security** | No P0/P1; well-hardened | Inbound magnet confirm defaults on (it seeds, not just downloads); new connections default to SFTP with a plaintext warning; a release gate fails a build that still has the placeholder Sparkle key. |
| **Testing** | Strong, with corner gaps | The cross-volume move (the one path that deletes your original) is now tested against a real RAM disk; redo-of-Replace, the Trash Put-Back ledger, copy-verify cleanup, and the near-dup keeper are covered; the flaky FSEvents test is deflaked; **CI now runs automatically** on code pushes/PRs. |
| **Accessibility** | Was name-only | All five file views (list, icon, column, gallery, tree) speak name + kind + size + date to VoiceOver. |
| **Product / stars** | Breadth already beats Path Finder / ForkLift | `make gate-a` reproduces the benchmark; grouped duplicate-resolve UX (keep one, trash the set); batch-rename `{date}`/`{exif}` tokens + saved presets; first-run demo-workspace tour; the Shelf is now the "Drop Stack". |

## What still needs you (not buildable-and-verifiable by an agent)

**1. The 1M-row scroll proof is shipped.** `make gate-a-demo` renders the real AppKit
table in-process, then produces the above-the-fold README GIF and site MP4. It does
not need Screen Recording permission. `make gate-a` independently enforces that the
million-row table materializes only a bounded number of cells.

**2. Publish the VS Code / Cursor extension.** Authored, packaged, installed
locally, and CI-ready (`.github/workflows/vscode-extension-release.yml`). Needs
your Marketplace publisher account:
`cd Integrations/vscode-pathem && npx @vscode/vsce publish` (or push a
`vscode-v0.1.0` tag once `VSCE_PAT` is set).

**3. Localization phrasing (optional, post-public, not a blocker).** Coverage,
plist validity, and printf format-specifier consistency are all gated in CI, so no
translation can crash or garble the UI. What's left is *phrasing* quality: the
fr/de/es/ja/zh-Hans strings are AI-generated and provisional, and only a native
speaker can polish them. That's inherently a crowdsourced, post-public task (going
public is what surfaces the volunteers). Two honest choices: ship the provisional
translations as-is and invite fixes (worst case is an awkward phrase, strictly
better than a missing feature), or drop the five locales and ship English-only if
you'd rather not show unreviewed strings. Either way it does not block the flip.

**4. The public flip itself.** Gated on your user-testing bar. See
`LAUNCH_CHECKLIST.md` §1 for the exit criteria and §4-5 for cutting the notarized
build and flipping the repo. Requires a paid Apple Developer account and the
Sparkle key set up.

## Deferred bets (resolved)

- **SFTP "new host key, accept?" prompt: shipped.** The first SFTP connection to
  an unpinned host shows its scanned fingerprint for confirmation (HostKeyCheck).
- **Photos edit-back: safe slice shipped.** Remove Location clears GPS from
  selected photos via `PHAssetChangeRequest` (metadata only, revertible in Photos).
  The full content edit-back (crop/adjustments via `PHContentEditingOutput`) stays
  a larger future item.
- **Precomputed collation sort keys: declined by design.** Foundation exposes no
  ICU collation-key API, so any precomputed key sorts non-ASCII by codepoint, which
  diverges from `localizedStandardCompare` and breaks the enumerator contract test.
  Left as-is.

## Recommended sequence

1. Publish the VS Code extension (item 2): a second, independent star surface.
2. When your testing bar is met, run `LAUNCH_CHECKLIST.md` end to end (item 4).
3. After public, invite translation fixes as issues/PRs come in (item 3).

Bottom line: the engineering the audit surfaced is complete. What remains is
launch production and the gated flip, all of which are yours to trigger.
