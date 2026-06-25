# Pathem end-to-end (blackbox) tests

These exercise the **built product** from the outside, the way a user's launch does, to
catch what unit tests can't: launch crashes, packaging gaps, layout collapses, and the
on-device AI path. There is no access to app internals; each scenario is driven by a
`PATHEM_*` environment switch the app understands and is judged by the `RESULT:` line it
prints to stdout.

## Run

```bash
make e2e              # fast: against the debug `swift build` binary
make e2e-app          # against the signed .app from scripts/package.sh
# or directly:
test/e2e/run.sh
test/e2e/run.sh --packaged
```

`run.sh` exits non-zero if any scenario fails; SKIP (e.g. AI unavailable on this Mac)
does not fail the suite.

## Scenarios

| Scenario | Switch | Asserts |
|---|---|---|
| launch + UI invariants | `PATHEM_SMOKE` | window/panes/sidebar laid out, terminal opens |
| 1M-row virtualization | `PATHEM_GATE_A` | the list materializes only visible cells |
| localization | `PATHEM_L10N_SMOKE` | all six `.lproj` bundled and resolving |
| organize with AI | `PATHEM_AI_SMOKE` | on-device model proposes a plan (SKIP if no Apple Intelligence) |
| settings / sidebar render | `PATHEM_PREFS_SHOT`, `PATHEM_SIDEBAR_SHOT` | panels render to non-empty images |

`--packaged` additionally verifies the assembled `.app` is complete (binary, resource
bundle, all six languages) before launching it — the regression guard for the
missing-resource-bundle launch crash.

## Adding a scenario

1. Add a `PATHEM_<NAME>` branch in `Sources/Pathem/PathemApp.swift` that runs headless,
   prints `RESULT: PASS|SKIP|FAIL`, and `exit`s.
2. Add a `scenario "..." 'RESULT: ...' env PATHEM_<NAME>=1 "$BIN"` line to `run.sh`.
