# Encrypted disk image creation: intermittent "Resource busy"

Trigger: Mission 53 task 42. Codex's full CI (CI30116) failed one check,
`encrypted-disk-image-created` in the deterministic archive scenario: `hdiutil create`
reported `Resource busy` after the eight earlier archive checks passed. An isolated
rerun passed 10/10, so the failure is intermittent.

`DiskImage.createEncrypted` stages the items in a temp folder and runs
`hdiutil create -encryption AES-256 -stdinpass -srcfolder <staging> -format UDZO`.
The same call backs the user-facing "Create Encrypted Disk Image" command.

Hypothesis, not yet convicted: the failure is macOS contention inside `hdiutil`, not
Pathem logic. With `-srcfolder`, `hdiutil` builds and mounts an intermediate volume,
copies the files, detaches it, then converts it; if another process (Spotlight, a malware
scan, fseventsd) still holds that volume, the detach fails as busy. This failure is
widely reported on CI Macs.

Criteria, written before the sample:

- D1 Reproduction outside Pathem: the identical `hdiutil create` command, run directly in
  a loop (idle, then under synthetic CPU and disk load), produces `Resource busy` at least
  once, with exit code and stderr recorded. If 0 failures in all runs, the hypothesis is
  unconfirmed and only an instrument ships (fuller error detail), not a retry.
- D2 Transience: when a run fails, an immediate retry of the same command succeeds. If
  retries also fail, a retry is the wrong fix.
- D3 Specificity: a deliberately bad call (missing source folder) fails with a different
  message, so any retry can be keyed to the busy error alone and real errors still
  surface at once.
- D4 Only if D1 to D3 hold: `createEncrypted` retries a bounded number of times on the
  busy error only. Engine tests with an injected runner prove: busy then success
  returns the image; busy every time fails after the bound with the original message;
  any other error fails on the first attempt with no retry.

What would mean the design is broken: a retry that also swallows non-busy errors, or one
justified by a sample that never reproduced the failure.

Not claimable: which macOS process holds the volume. The retry would address an OS-level
race whose internal cause stays unconvicted.

## Sample 1 (2026-10-13): D1 not met

Standalone runs of the exact command, outside Pathem: 0 failures in 40 idle runs and 0
in 30 runs under synthetic load (4 CPU spinners plus a looping 200 MB disk writer), about
6 s per run. With Codex's isolated 10/10, the failure is not reproduced outside a full
CI run. D3 holds: a missing source fails with `create failed - No such file or
directory`, exit 1, distinct from the busy message. Per the criteria, no retry ships.

Side finding, not acted on: on this macOS, `hdiutil create` with `-volname`, `-format`
and `-encryption` prints a deprecation warning recommending `diskutil image create`.

## Instrument instead of a fix

The archive scenario's disk-image step used to throw, aborting the scenario and skipping
every later archive check. It now catches the error and records it with the number of
attached images and the result of one immediate diagnostic retry. The check still fails
whatever the retry does, so the next CI occurrence reports itself as transient or
persistent without anything being masked.

Criteria for the instrument:

- I1 Injected (`PATHEM_E2E_INJECT_DMG_FAILURE`, first attempt uses a missing source):
  `encrypted-disk-image-created` FAILS, its detail names the missing-source error,
  `attached-images=<n>` and `diagnostic-retry=ok`, the later archive checks still run
  and pass, and the scenario reports FAIL.
- I2 Not injected: the scenario passes with the same check names as before.

Instrument results (2026-10-13, isolated debug launches):

- I1 PASS. Injected run: `encrypted-disk-image-created` FAILS with the missing-source
  error (NSCocoaErrorDomain 260), `attached-images=8`, `diagnostic-retry=ok`; the later
  `damaged-archive-fails-without-clobbering-existing-files` check still runs and passes;
  RESULT FAIL (10 checks).
- I2 PASS. Ordinary run: 10/10 with identical check names, and no `Pathem-E2E` image
  left attached.
- Baseline for reading future failures: all 8 attached images on this Mac are system
  images (iOS Simulator runtimes and the Metal toolchain, which macOS attaches twice), not
  test leftovers. A busy failure reporting more than this baseline, or any `Pathem-E2E`
  image, would point to a leaked attach.

Task 42 stays open: the failure is not reproduced and no fix ships. The next CI
occurrence will show whether an immediate retry succeeds (transient contention) or not.
