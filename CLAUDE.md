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
center. Its machine contract is `commandem.toml` at the repo root
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

## Use American spelling

Write American English in everything you produce: code comments, identifiers you create, user-facing text, docs, commit messages and replies (color, behavior, center, license, organize, favorite, gray, canceled). Do not rename existing identifiers, file names or stored keys just to change their spelling; those are frozen.

Why: mixed British and American spelling crept into a product written for American users when agents copied the spelling of their instructions.

## Format longer replies with headings

When a reply runs more than about 12 lines or covers more than one topic, use markdown ## or ### headings for its sections, one blank line around each; never a plain line ending in a colon as a section title; short replies stay plain. No headings inside code blocks.

Why: headings let the owner scan a long reply, and plain colon lines could not be told apart from ordinary sentences, so the format has to come from the agent.

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

## Isolate concurrent repository work in a small pool of workbenches

Before changing files in a tracked repository, check `commandem workbench ls
<project>`. When another agent or session may be working in the repository,
make implementation changes in a workbench rather than the primary checkout,
and REUSE a small fixed pool of workbenches instead of creating one per task:

- Use at most four workbenches per provider per repository, with stable names
  such as `claude-1` .. `claude-4` or `codex-1` .. `codex-4`. Create one with
  `commandem workbench new <agent> <project>` only when every existing slot is
  busy and fewer than four exist. Never create a workbench for a single task.
- Work from the directory `commandem workbench ls <project>` reports. Keep the
  primary checkout as the integration lane; do not leave new source or test
  files there while concurrent work is possible.
- Commit one coherent unit and run `commandem workbench land <agent>
  <project>` so the branch returns to trunk. Keep the workbench (no `--rm`):
  the next task starts in the same slot with a warm build.
- Respect this machine's build limit. How many full app or Swift builds can
  run at once depends on the computer (a fast laptop may handle two, a smaller
  one only one, a large workstation more); the owner sets it per machine. Until
  `commandem` exposes the limit, run heavy builds, test runs and commits whose
  hooks build one at a time under the shared lock:
  `lockf -k /tmp/commandem-swift-build.lock <command>`, with capped jobs
  (e.g. `COMMANDEM_SWIFT_JOBS=4`). Run one `go test` at a time, scoped to the
  packages you changed.
- Remove a workbench only with `commandem workbench rm <agent> <project>` (or
  `workbench prune`), never by deleting its folder: a deleted folder leaves a
  dead project entry behind.
- Never run `git stash` in a workbench: stashes are shared by every worktree
  of the repository, so a pop can apply another lane's changes. Set work aside
  with a temporary WIP commit on your own branch instead.
- If work already began in the primary checkout, migrate only the changes you
  own into your workbench. Preserve every other dirty or untracked file.

Why: one workbench per task produced 102 registered workbenches (66 of them
dead entries) and hundreds of GB of copies, and eight parallel full builds
drove load to ~400 on a 16-core Mac so every build and hook timed out
(2026-11-12). Do not bypass a workbench or its commit gate to save time;
isolation is part of finishing the work, not an optional cleanup step.

## Wait for background work without sleep loops

When you are waiting on a long-running command, build, test run or agent,
do not poll with `sleep N && <check>` chains: the agent harness refuses them,
and each poll wastes a turn. Start the work in the background and let its
completion notify you (in Claude Code: `run_in_background`, or the Monitor
tool with an until-loop for a condition). macOS ships neither GNU `timeout`
nor `tac`; Commandem supplies fallbacks on an agent's PATH, but prefer
bounded tools over wrapping commands in `timeout`.

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
materially advance a Mission, update it in the SAME session via
`commandem roadmap <project>` — mark finished tasks/Missions done, flip the
Mission you are working on to `now`, and add a new Mission for new work you
took on. Do not let shipped work go unrecorded, and do not wait to be
asked.

If you are working from an agent workbench (a linked git worktree, its own
registered project distinct from the base repo), `<project>` means YOUR
WORKBENCH'S OWN registered project name, not the base project's name —
`commandem roadmap <base-project>` resolves by name regardless of your cwd,
so run from a workbench it silently writes the base checkout's
commandem.toml instead of yours. `commandem roadmap`/`manifest --write`/
`policy add`/`roles set`/`limits set`/`prefs --set` all refuse a write whose
cwd sits in a different git worktree than the resolved project and name the
correct pattern to use instead; pass the verb's own `--primary` flag only
when you deliberately mean to edit that other worktree from here.

A healthy roadmap always names current work: at least one Mission in `now`
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
- Record the why where the next reader will look: the roadmap Mission
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

## Validate an experiment on a sample before the full run

Before launching any experiment, benchmark, evaluation batch, or other
research run at full scale, run a small sample and confirm the DESIGN is
validated -- not merely that the pipeline produced output. A full run
requires all of the following, reported to the owner with evidence:

- **Criteria written first.** Before the sample runs, write its pass/fail
  criteria into the study root (e.g. `PREREGISTRATION.md`), including the
  result that would mean the design is broken.
- **The instrument can discriminate.** Ask: if the hypothesis were false,
  could this setup show it? Include at least one control whose correct
  result differs from the expected-looking one (a synthetic cheater that
  must score as cheating, a known-good case that must pass, a known-bad
  case that must fail) and run it through the real pipeline. A check that
  can only ever produce one outcome validates nothing -- a gate never seen
  red is not known to work.
- **The treatment was delivered.** Confirm the agent or system actually
  received what the design depends on (saw the input, ran the command,
  hit the condition), from logs, not from the shape of the output.
- **A verdict per criterion.** State pass/fail for each criterion with the
  evidence. "Matches the pattern I expected" is not a verdict.
- **Owner go-ahead.** When the full run spends real quota, money, or hours,
  present the validation verdict and get approval before scaling.

If the sample contradicts the design or a criterion fails, stop and fix
the design. Never scale an unvalidated design to see what happens.

This directive exists because on 2026-10-03 a 346-task SWE-bench run was
scaled overnight on a 3-task "validation" whose outcome was guaranteed by
construction (the agent never saw the impossible test), wasting the full
run's tokens and time before anyone noticed.

## Scope board posts to the project they're about

`commandem tell <target> "<msg>"` posts to one project's thread; `tell all`
fans the SAME post out to every registered project's board. Reserve `all`
for messages that are genuinely relevant fleet-wide (a cross-project
advisory, a shared outage). Multi-agent coordination chatter about one
project's own work -- build status, a land/push sequence, an install,
an ownership check with another agent -- belongs to that ONE project's
thread (`tell <project>`), never `all`.

- Before posting, ask: would an unrelated project's owner want this in
  their history? If the answer is no, it is not an `all` message.
- A long back-and-forth with another agent (Codex, a sibling Claude lane)
  working on the SAME project stays scoped to that project's thread for
  its entire duration, not just the first message.
- `tell all` posted dozens of times in one session is itself a signal
  something is misscoped -- stop and recheck the target before continuing
  a pattern like that.

This exists because a multi-hour Codex coordination session posted 39
internal build/install status updates to `tell all`, landing unrelated
noise on every one of ~80 registered projects' boards -- entirely
avoidable by addressing the one project the conversation was actually
about.

## Coordinating lanes: a silent lane is a usage problem until proven otherwise

When you coordinate other agent lanes and one goes quiet, stops replying, or
reads as "idle", check its ACCOUNT USAGE LIMIT first. Do this before you wait,
re-send status pings, or tell the owner you are "waiting on" it.

- Map the lane to its process and account (for example the `--account` on its
  `commandem chat --agent ...` process) and check that account's weekly or
  short-window usage.
- "Accepted by a live lane" in announce history means the note reached a chat
  process. It does NOT mean the agent can act on it.
- If the lane is usage-limited, say so to the owner immediately. Then hand its
  remaining work to a lane on an account WITH headroom, preferably one already
  waiting and already holding the context, and tell the limited lane to stand
  down so the work cannot be done twice.
- Never leave owner-visible work stalled behind a lane you have not confirmed
  can act.
- Re-resolve every lane address immediately before EACH send. An app relaunch
  changes lane addresses, and a stale address can still report "accepted" while
  delivering to a different lane, such as one at 100% usage. Map address to
  session (`announce --lanes --json`), session to account (the chat process's
  `--account`), and account to usage (`commandem usage --fleet --json`). Re-check usage before every reassignment as well, so you do not hand
  work to another limited lane.

This exists because on 2026-10-30 a recovery lane silently hit its Codex
account limit mid-delivery, and the coordinator kept reporting "waiting on it"
for hours. Meanwhile a lane on a different account sat idle with the context
needed to finish. The owner had to point that out and reassign the work by
hand.

## Structure replies so they can be scanned

The owner reads replies in a themed chat that colours headings, bold lead-ins,
lists, code and status words. A reply written as one plain paragraph gets none
of that. When a reply has more than one point:

- Start with one plain sentence giving the outcome.
- Use a short `##` heading per topic when there are two or more topics.
- Use a bullet per item, each opening with a short **bold** lead-in.
- Put commit ids, file paths, commands and identifiers in `backticks`.
- Use a small table for results across several items.

Do not pad: structure is for scanning, not length. A one-line answer stays one
line.

## Lessons from your own history

Historical notes, not standing directives. Dates identify when notes were recorded; explicit supersessions are excluded.

- [2026-11-17; mem-f345a210dfd3] docs(roadmap): record the theme gap fixes Files changed: commit 3c65e5ac05a909c41aa3a4b9cb55d0f721b71561 Author: Scarcrux <scarcrux@users.noreply.github.com> Date: Tue ...
- [2026-11-17; mem-08f791504c69] docs(roadmap): record the title bar tint fix Files changed: commit 3d06cdfc3abe6cc70352064c71ac011a88c7e4ae Author: Scarcrux <scarcrux@users.noreply.github.com> Date ...
- [2026-11-17; mem-ce522832aed3] docs(roadmap): correct the order of the sliver fix record Files changed: commit e6c784cb86e197a84a2c59cf2dac3129753f5148 Author: Scarcrux ...

<!-- commandem:managed:end -->
