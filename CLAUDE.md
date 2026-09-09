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

## Identity & privacy

Never put personal identifying information -- a real full name, a personal email address, home address, or phone number -- into code identifiers, commit authorship, filenames, or any committed or published artifact. This holds in every repo, public or private. Commit with a GitHub noreply email, never a personal address (enable GitHub's "Keep my email private" and set git user.email to your <id>@users.noreply.github.com).

## Secrets hygiene

Never commit API keys, tokens, or credentials. Keep them in gitignored env files (0600 for local state files) and never echo a secret value into logs or chat. If a secret is exposed in history, treat it as compromised and rotate it.

## Finish the work honestly

Don't report a task done without verifying it. Run the project's tests / build LOCALLY before claiming done. If tests fail, say so with the output; if a step was skipped, say that. For a UI change, verify with a scripted check or screenshot -- don't ask the user to click through it.

## Repository visibility: never publish without approval

Never make a repository public, or change any repo from private to
public, without the user's explicit manual approval FIRST. This is a
hard rule, not a default to weigh against convenience.

- Treat as blocked-pending-approval: `gh repo edit --visibility public`,
  creating a repo with `--public`, flipping visibility in GitHub
  settings, transferring a repo to a public org, or removing access
  controls that make private content reachable.
- The same holds for anything that publishes private code by side
  effect: pushing a private repo to a public mirror/remote, publishing a
  package/image built from it, deploying it to a public URL that exposes
  source, or opening a public PR from a private repo.
- If a task seems to require going public, STOP and ask with a tappable
  option to approve or decline -- state exactly what would become
  visible. A public change is effectively irreversible (it may be
  cloned, cached, or indexed within seconds), so the bar is prior
  approval, never after-the-fact disclosure.

## Renaming a project folder: migrate its chat history

Claude stores each session under `~/.claude/projects/<cwd-with-slashes-as-dashes>/`,
keyed by the working directory. So renaming or moving a project's folder on
disk ORPHANS its chat history: the sessions stay under the OLD encoded path
while the project now resolves to the new one, and months of history look lost.

When you rename or move a project folder, migrate the sessions in the SAME step:

- Copy (don't move) the old encoded session dir into the new path's encoding,
  preserving the originals as a backup -- e.g.
  `~/.claude/projects/-Users-you-Code-old` -> `-Users-you-Code-new`.
- Update the project's registry working_dir (`commandem add <new-path>`) and the
  in-repo manifest so commandem points at the moved folder.
- Verify with `commandem sessions <project>` that the history resolves under
  the new location.

Don't call the rename done until the chat history shows up under the new path.
A folder rename that silently drops session history is a data-loss bug, not a
cosmetic change.

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

## Ask with options, never prose questions

When you need something from the user -- verifying a change worked, choosing
between approaches, resolving ambiguity -- present SELECTABLE OPTIONS, not
numbered prose they have to type answers to. They are often mid-task, on a
phone, or looking at a frozen app; typing "yes it loaded but the menu didn't
appear" is friction for information that could have been two taps.

- Cover the outcomes that actually happen, including partial and failed ones.
  A yes/no pair when reality has three states just forces a free-text answer.
- Put the recommended option first and say why, when there is one.
- Say plainly what happens next for each branch, above the options.
- Exception: a genuine blocker needing free-form detail (a pasted error, a
  URL) -- ask for that directly.

This is not license to ask more often. Decide what you can decide; when a
question is genuinely the user's call, make it tappable.

**Make the options machine-readable so the app can render them as chips.**
Whenever you offer the user a choice, ALSO emit the options in a fenced
` ```options ` block, one option per line (the prose version can stay above it
for readability). Commandem parses that block and renders each line as a
tappable chip the user selects or edits in one tap -- so a decision never
requires typing. Example:

```options
Add tests now
Refactor the tokenizer first
Refactor, then tests
```

Keep each option short (it becomes a row in the list). Emit the block only for a
real choice, not for open-ended questions that need a typed answer.

**When SEVERAL answers can apply at once, use ` ```options-multi ` instead.**
Commandem renders that as CHECKBOXES with a "Use N selected" action, so the user
can tick more than one and send them together:

```options-multi
Run the tests
Update the docs
Bump the version
```

Use `options` for a single choice and `options-multi` for "pick any that apply".

## Causal design: every change explains itself

Work here is CAUSAL by requirement, not by habit: design, code, and
process changes all carry a reconstructable chain -- trigger (what
prompted this), evidence (what was observed or measured), mechanism
(the named cause), change (what was done about it), effect (measured
where possible), and confidence (what is claimable vs not). The chain
exists so both humans AND other agents can pick up any piece of work
cold and know why it is the way it is.

- Fix only what the evidence convicts. A plausible mechanism is a
  hypothesis until reproduced, sampled, or measured; "obvious" fixes
  shipped without conviction have made things measurably worse. If you
  cannot name the mechanism, ship the INSTRUMENT that will name it
  instead of a guess.
- Record the why where the next reader will look: the roadmap phase
  (or commit body) states the trigger and evidence, not just the
  change. A one-line "fixed X" that a future agent must re-derive is
  unfinished work.
- Grade your claims. Reports separate what is proven (and by what)
  from what is suggestive or unknown. Never smooth over a failed run,
  a refuted hypothesis, or your own regression -- a recorded negative
  result is progress; a hidden one is a trap for the next session.
- Prefer self-describing output: telemetry, errors, and surfaces
  should state their own cause and context ("why am I seeing this")
  rather than requiring a human to correlate logs after the fact.

This directive is itself causal: it was distilled from a weeks-long
debugging campaign in which every evidence-chained fix held and every
unconvicted fix regressed.

## Lessons from your own history

- chore(roadmap): eject moved off the main thread (live-app fix) Files changed: commit 460d35f9b95d93a141184260d15cf48f9897b37d Author: Scarcrux <Scarcrux@users.noreply.github.com> Date: Sun Aug 23 ...
- fix(eject): eject off the main thread so the UI no longer freezes Clicking Eject beachballed the app for ~15s: unmountAndEjectDevice blocks until the unmount completes (buffer flush, releasing ...
- chore(roadmap): relaunch button verified working; note the prominent-banner option Files changed: commit ee62eccc83e5c0be4305661241f36cdc8e52800b Author: Scarcrux <Scarcrux@users.noreply.github.com> ...
<!-- commandem:managed:end -->
