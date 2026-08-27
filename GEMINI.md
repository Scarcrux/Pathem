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

- chore(roadmap): record Finder-style Dock menu (live-app fixes 5) Files changed: commit 7b84da2fa684ac1d86bafa35b1e8f8c7d8eb6c17 Author: Scarcrux <Scarcrux@users.noreply.github.com> Date: Tue Aug 11 ...
- feat(dock): Finder-style Dock menu (New Window, New Tab, open tabs) Right-clicking the Dock icon showed only the OS defaults because Pathem never implemented applicationDockMenu. Add one: New Window ...
- chore(roadmap): record breadcrumb spring-loading (drag report, paths half) Files changed: commit 4daaaa0db186b0d4f466031cb641024d920dcd2e Author: Scarcrux <Scarcrux@users.noreply.github.com> Date ...
<!-- commandem:managed:end -->
