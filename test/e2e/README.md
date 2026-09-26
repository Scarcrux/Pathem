# Pathem end-to-end (blackbox) tests

The debug suite launches the **built product** as a separate process and drives its dedicated
automation entry points. It catches launch crashes, packaging gaps, layout collapses, daemon
protocol failures, real-file regressions, and on-screen interaction bugs. The packaged suite is
different by design: release builds contain no debug hooks, so it checks the bundle/signature and
launches the release binary externally, using Accessibility for a visible-window assertion when
the runner has permission.

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
| torrent daemon seam | `PATHEM_TORRENTS_SMOKE` | app spawns daemon; `.torrent` and magnet commands appear in status |
| create + rename | `PATHEM_E2E` | real folder/file creation and rename reach disk |
| on-screen interactions | `PATHEM_UI_TEST` | 39 real-window rename/move/view/toolbar interaction checks |
| settings / sidebar render | `PATHEM_PREFS_SHOT`, `PATHEM_SIDEBAR_SHOT` | panels render to non-empty images |

`--packaged` verifies the release `.app` has its binary, resource bundle, six languages, three
out-of-process helpers, and a valid nested signature. It then launches the real release binary and
requires it to remain alive. The Accessibility window check is reported as SKIP rather than a false
pass when the invoking terminal/runner has not been granted Accessibility permission.

## Adding a scenario

1. Add a `PATHEM_<NAME>` branch in `Sources/Pathem/PathemApp.swift` that runs headless,
   prints `RESULT: PASS|SKIP|FAIL`, and `exit`s.
2. Add a `scenario "..." 'RESULT: ...' env PATHEM_<NAME>=1 "$BIN"` line to `run.sh`.
