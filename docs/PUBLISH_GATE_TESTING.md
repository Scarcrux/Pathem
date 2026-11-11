# Publish gate acceptance criteria

Trigger: Mission 53 task 5. `PUBLISH=1 scripts/release.sh` could upload an ad-hoc,
un-notarized DMG with an unsigned appcast (a missing Sparkle signature only warned and
fell back to a length-only enclosure), and nothing ran the test gate first. The tag
workflow published a ZIP while README, RELEASE.md and LAUNCH_CHECKLIST.md promise a
notarized DMG, derived its own build number, and never ran the gate either.

Criteria written before implementation:

Preflight. With `PUBLISH=1`, before any build, gate run or GitHub write, the script
refuses (non-zero exit, message naming the failed requirement) unless all hold:

- P1 `DEVELOPER_ID` is set and looks like `Developer ID Application: <name> (<10-char team>)`.
- P2 `NOTARY_PROFILE` is set.
- P3 `SUPublicEDKey` in `Packaging/Info.plist` is not the placeholder and decodes to a
  32-byte Ed25519 public key.
- P4 If `SPARKLE_KEY_FILE` is set, it is a readable file. (A Keychain key is not probed;
  the post-build signature check below catches a missing or wrong key either way.)
- P5 `gh` is installed and authenticated.
- P6 The working tree is clean and `HEAD` is exactly the tag `v<CFBundleShortVersionString>`,
  so the published artifact is the tagged source.
- P7 The release tag does not already exist on GitHub (existing check, kept).

Gate. G1 With `PUBLISH=1`, `make ci` runs and must pass before packaging. A gate failure
stops the script before the app is built or anything is uploaded.

Artifact verification. Before any upload, the built app and DMG must pass
`scripts/verify-release.sh`:

- A1 `codesign --verify --strict --deep` passes.
- A2 The leaf authority is `Developer ID Application` and the TeamIdentifier equals the
  team in `DEVELOPER_ID`.
- A3 The hardened runtime flag is set on the main executable.
- A4 `stapler validate` passes (a notarization ticket is stapled).
- A5 Gatekeeper accepts it (`spctl --assess --type execute`).
- A6 Every Mach-O executable in `Contents/MacOS` contains both arm64 and x86_64.
- A7 The DMG's EdDSA signature verifies against the `SUPublicEDKey` inside the built app
  (not just the source plist), so installed copies can accept the update.
- A8 The appcast enclosure carries that exact signature, the DMG's byte length, and the
  tag's download URL. No unsigned fallback enclosure is ever produced under `PUBLISH=1`.

Workflow and docs. The tag workflow publishes the same DMG and appcast through
`scripts/release.sh` (so G1 and A1-A8 apply), refuses a tag that does not match the
committed `CFBundleShortVersionString` instead of rewriting Info.plist, and keeps the
committed `CFBundleVersion`. RELEASE.md describes exactly this behaviour.

Non-publish dry runs (`PUBLISH` unset) still need no credentials and still produce
inspection artifacts, clearly marked as not distributable.

Controls. Each must traverse the real script, not a helper:

- Every preflight requirement has its own failing case, each run with all other
  requirements satisfied, and must be refused for that reason only.
- A fully satisfied preflight must pass and reach the gate. In the hermetic harness the
  gate then fails (no Makefile in the scratch root), which must stop the run before
  packaging and before any `gh release create`. This is the gate-failure control.
- A synthetic cheater (a stub that skips preflight and calls `gh release create`) must be
  reported as FAIL by the harness, proving the harness can go red.
- A fake `gh` on `PATH` records every invocation; any `release create` or `upload` in a
  refused run fails the criterion.
- Artifact verifier: a real Developer ID, universal, stapled third-party app must pass
  A1-A6; an ad-hoc app (fails A2), an arm64-only stapled app (fails A6), an unstapled
  app (fails A4) and a team mismatch (fails A2) must each fail for their own reason.
- Signature: a throwaway key generated in a temp directory (never the Keychain) must give
  ACCEPT for the correct key, and REJECT for a tampered DMG, a different public key, a
  placeholder key and malformed input.

What would mean the design is broken: any refused run that still invokes a GitHub write,
a satisfied preflight that never reaches the gate, a verifier that passes the ad-hoc or
arm64-only app, or a signature check that accepts the tampered DMG.

Not claimable locally: an end-to-end publish with a real Developer ID, notarization and
Sparkle key. No credentials, Keychain writes, tags, releases or publication are used.

## Validation (2026-10-12)

Sample first. The signature instrument was built and checked before use: a throwaway
Ed25519 key from CryptoKit in a temp directory, signed by Sparkle's own `sign_update
--ed-key-file` (it accepts the 32-byte seed form and rejects the 64-byte form), gave
ACCEPT for the correct key and REJECT for a tampered file, a different key and malformed
input.

The first verifier sample failed its positive control, and that was an instrument bug,
not a product finding. The notarized universal control app failed A3 and A5, and so did
the installed ad-hoc Pathem, which is signed with `--options runtime`. Two causes:
`codesign | grep -q` under `pipefail` reports failure when grep closes the pipe early
(SIGPIPE), and `spctl` is in `/usr/sbin`, which was not on `PATH`. Both are fixed: output
is captured before matching and `spctl` is called by absolute path. The same SIGPIPE
pattern in the A6 Mach-O filter, where a spurious failure would have silently skipped an
executable, was fixed the same way.

Verdicts:

- P1-P7: PASS. `test/release/publish_gate_test.sh` gives 17/17. Every requirement has its
  own refusal case, each refused for that code alone, with no gate, build or `gh` write.
  It runs under `/bin/bash` 3.2 with `env -i`.
- G1: PASS for local ordering. A satisfied preflight reaches `make ci`, and a gate failure
  stops before packaging and before any `gh release create`.
- Harness discrimination: PASS. The synthetic cheater is reported FAIL. Against the
  pre-change `release.sh` from `main` the same harness fails 15 of 17. Every credential,
  key, `gh` and git case reached the build. The dry-run case passes on both, as it should.
- A1-A6: PASS. AdGuard VPN (Developer ID, universal, stapled) passes all six. Antigravity
  fails A6 only (arm64). Battle.net fails A4 (unstapled), plus A3 and A6. The installed
  ad-hoc Pathem and a fresh ad-hoc build fail A2, A4, A5 and A6. A wrong expected team
  fails A2 only. Battle.net passing Gatekeeper (A5) without a stapled ticket is why A4 is
  checked separately.
- A7, A8: PASS on a real dry-run artifact (9.5 MB DMG, signed through `SPARKLE_KEY_FILE`
  with a throwaway key, so the Keychain was never read). The matching public key gives
  ACCEPT. The built app's placeholder key, a truncated DMG, a length mismatch, a wrong
  URL and a stale unsigned item in the feed each FAIL for their own reason.
- Dry run (`PUBLISH` unset, no credentials): PASS. It built, made the DMG, signed it with
  the throwaway key and wrote the appcast, exit 0.

Not claimed. No end-to-end publish was run with a real Developer ID, notarization or
Sparkle key. The tag workflow is unexercised. It runs `make ci` on GitHub's `macos-15`
image, whose Xcode may not match the local Xcode 27 warning baseline, so the gate there
may refuse a good release. That fails closed and publishes nothing, but the runner image
needs checking before the first tag. Whether a tag created by `gh release create` also
starts the tag workflow is not verified. If it does, that run refuses at P7.

## Updater isolation for release-test launches (2026-10-13)

Trigger: committing a real `SUPublicEDKey` (bca8f3e) activated Sparkle in every packaged
build. The packaged E2E probe launches the release app with `PATHEM_RELEASE_TEST`, under
the same bundle ID as the owner's installed app, so Sparkle fetched the (private, 404)
feed and wrote `SUHasLaunchedBefore` and `SULastCheckTime` into the owner's real
`com.scarcrux.pathem` defaults. Evidence: `SULastCheckTime` was 03:28 local while the
owner's only Pathem process was started the day before on a placeholder-key build.

Change: `UpdaterController` never starts the updater when `PATHEM_RELEASE_TEST` is set,
and says so on stdout; the packaged probe asserts that line.

Criteria, written before the sample. The two Sparkle keys are first removed from the
owner's defaults; only test launches ever created them.

- U1 Control: a release-test launch of the unfixed build (main 6fedb20) recreates
  `SUHasLaunchedBefore`. If it does not, the launch never exercised the leak and U2
  proves nothing.
- U2 Fix: the same launch of the fixed build leaves both keys absent and prints
  `UPDATER: disabled for release test`.
- Not exercised: a normal (non-test) launch still starting the updater, because that
  launch would use the owner's real configuration. Checked by reading the code: the
  only change to `isConfigured` is the added `!isReleaseTest` term.

Results (each a release-test launch with a scratch config, stopped after 8 s, owner
Sparkle keys removed beforehand):

- U1 PASS (red as required): the unfixed main build recreated `SUHasLaunchedBefore` and
  `SULastCheckTime` (a fresh check at 08:50 UTC).
- U2 PASS: the fixed build left both keys absent and printed the line. The first fixed
  run left the keys absent but lost the line, because `print()` output to a file is
  buffered and the probe ends the app with SIGTERM; the line now uses an unbuffered
  write, the same as the other test hooks.
- Full `test/e2e/run.sh --packaged`: 14/14, including the new assertion, with the owner's
  Sparkle keys still absent afterwards.

## DMG signing and notarization (2026-11-11)

Trigger: the first full local dry run produced a DMG that was not signed or notarized
itself (`spctl`: "no usable signature"); only the app inside was.

Change: `release.sh` signs the DMG with Developer ID, notarizes and staples it when a
notary profile is set, and does so before the Sparkle signature, because stapling changes
the file. `verify-release.sh dmg` (A9) checks the Developer ID leaf and team, the stapled
ticket and Gatekeeper acceptance, and a publish must pass it.

Results from a second dry run (`PUBLISH` unset, nothing uploaded to GitHub):

- A9 PASS on the produced DMG, 3/3. Both notarizations (app, DMG) were Accepted.
- A1 to A6, A7 and A8 still PASS, so the Sparkle signature covers the stapled DMG.
- Controls: an unsigned DMG fails all three A9 checks; the real DMG with a wrong expected
  team fails the team check only.

Not exercised: the A9 call inside a real `PUBLISH=1` run, and downloading the DMG in a
browser on another Mac (the quarantine path).
