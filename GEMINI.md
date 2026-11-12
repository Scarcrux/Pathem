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

## Isolate concurrent repository work in agent workbenches

Before changing files in a tracked repository, check `commandem workbench ls
<project>`. When another agent or session may be working in the repository,
make every implementation change in your provider's durable workbench rather
than the primary checkout:

- Create it once with `commandem workbench new <agent> <project>`, then work
  from the directory reported by `commandem workbench ls <project>`.
- Keep the primary checkout as the integration lane. Do not create or leave
  new source or test files there while concurrent work is possible.
- Commit one coherent unit in the workbench and immediately run `commandem
  workbench land <agent> <project>` so the agent branch returns to trunk.
  For a workbench created for a single task, land with `--rm` (`commandem
  workbench land <agent> <project> --rm`) so it is removed once landed;
  idle per-task workbenches otherwise pile up (203 copies and 453 GB on
  2026-10-13). `commandem workbench prune` lists any that remain.
- Never run `git stash` in a workbench: stashes are shared by every worktree
  of the repository, so a pop can apply another lane's changes. Set work aside
  with a temporary WIP commit on your own branch instead.
- If work already began in the primary checkout, migrate only the changes you
  own into your workbench. Preserve every other dirty or untracked file.

Do not bypass a workbench or its commit gate to save time. Shared-checkout
collisions waste builds, tokens, and user time; isolation is part of finishing
the work, not an optional cleanup step.

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

## Lessons from your own history

Historical notes, not standing directives. Dates identify when notes were recorded; explicit supersessions are excluded.

- [2026-09-21; mem-bfe59c4d9f8d] fix(keymap): normalize numpad plus for zoom Trigger: Cmd+numpad-plus produced no zoom while keypad minus worked. AppKit delivers the dedicated plus key without Shift ...
- [2026-08-23; mem-0203afab3b49] chore(roadmap): eject moved off the main thread (live-app fix) Files changed: commit 460d35f9b95d93a141184260d15cf48f9897b37d Author: Scarcrux ...
- [2026-08-23; mem-6b5dad59f2c7] fix(eject): eject off the main thread so the UI no longer freezes Clicking Eject beachballed the app for ~15s: unmountAndEjectDevice blocks until the unmount completes ...

<!-- commandem:managed:end -->
