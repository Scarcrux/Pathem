# Releasing Pathem

Pathem ships as a notarized, direct-download `.app` that auto-updates through
[Sparkle](https://sparkle-project.org) (EdDSA-signed appcast). It is not on the
Mac App Store (the sandbox can't grant Full Disk Access). This is the full
release runbook.

The two scripts do the work:

- `scripts/setup-sparkle-key.sh` — one-time EdDSA update-signing key setup.
- `scripts/release.sh` — build, sign, notarize, DMG, appcast, publish.

A dry run (no `PUBLISH=1`) skips any step whose credential is missing, so a bare
`scripts/release.sh` still produces a DMG and appcast in `dist/` for inspection.

Publishing fails closed. With `PUBLISH=1` the script refuses before building
anything unless every credential is present, `SUPublicEDKey` is a real key, `gh`
is authenticated, the tree is clean with `HEAD` at the version tag, and that tag
is not already released. It then runs `make ci`, and the built app and DMG must
pass `scripts/verify-release.sh` (Developer ID and team, hardened runtime,
stapled ticket, Gatekeeper, universal binaries, and a Sparkle signature that
verifies against the public key inside the app) before anything is uploaded.
The criteria and their controls are in `docs/PUBLISH_GATE_TESTING.md`.

There is also a CI path: `.github/workflows/release.yml` runs the same
`scripts/release.sh` with `PUBLISH=1` on a pushed `v*` tag, so it ships the same
DMG through the same gate, using repo secrets (the Developer ID certificate,
notary credentials, and `SPARKLE_PRIVATE_KEY`). It refuses a tag that does not
match the committed `CFBundleShortVersionString`. Use one path per release: push
the tag for a CI release, or run the script locally without pushing the tag
first. The one-time Sparkle key setup below is shared (CI reads the private key
from the secret; a local run reads `SPARKLE_KEY_FILE` or your Keychain).

## What you need once

### 1. Sparkle update-signing key (no Apple account required)

```bash
scripts/setup-sparkle-key.sh
```

This generates an EdDSA key pair, stores the **private** key in your login
Keychain, and writes the **public** key into `Packaging/Info.plist`
(`SUPublicEDKey`). Commit that Info.plist change.

Back up the private key immediately and keep it safe. It is unrecoverable, and
losing it means existing users can never accept another update (their installed
copy verifies every update against the embedded public key). Until this is run,
`SUPublicEDKey` stays `REPLACE_WITH_SPARKLE_PUBLIC_KEY` and Sparkle stays
dormant.

### 2. Apple Developer ID + notarization (needs a paid Apple Developer account)

This is the part that genuinely can't be automated without your Apple
credentials.

- A **Developer ID Application** certificate in your Keychain. Its identity
  string looks like `Developer ID Application: Your Name (TEAMID)`.
- A **notarytool** keychain profile, stored once:

  ```bash
  xcrun notarytool store-credentials pathem-notary \
    --apple-id you@example.com --team-id TEAMID \
    --password <app-specific-password>
  ```

  Create the app-specific password at <https://appleid.apple.com>.

The extension seam also expects helpers to be signed with **your** Team ID; set
the same `teamID` in any extension's `manifest.json`.

## Cutting a release

1. Bump the version in `Packaging/Info.plist`:
   - `CFBundleShortVersionString` — the marketing version (e.g. `0.9.0`).
   - `CFBundleVersion` — the build number, a monotonically increasing integer
     (Sparkle compares updates by this). Bump it every release.

2. Commit and tag:

   ```bash
   git commit -am "chore: release v0.9.0"
   git tag v0.9.0
   ```

3. Run the release:

   ```bash
   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
     NOTARY_PROFILE=pathem-notary \
     PUBLISH=1 \
     scripts/release.sh
   ```

   This will, in order:
   - check every publish requirement and refuse, listing each missing one;
   - run the full gate (`make ci`);
   - build a universal (arm64 + x86_64), Hardened-Runtime-signed bundle
     (`scripts/package.sh`), notarize and staple it, and verify the result;
   - wrap it in `dist/Pathem-<version>.dmg` with a drag-to-Applications target;
   - sign, notarize and staple the DMG itself, and verify it;
   - sign the DMG with your Sparkle key and verify that signature against the
     public key inside the app;
   - regenerate `dist/appcast.xml` (newest release first, each item pointing at
     its own tag's download URL) and refuse if any item is unsigned;
   - create the GitHub release `v<version>` at the verified commit and upload the
     DMG + appcast.

4. Push the branch and tag:

   ```bash
   git push && git push --tags
   ```

   If GitHub runs the tag workflow for this tag, it refuses because the release
   already exists; that is expected and publishes nothing.

The feed URL in Info.plist
(`https://github.com/Scarcrux/Pathem/releases/latest/download/appcast.xml`)
resolves to the newest release's `appcast.xml`, so uploading it in step 3 is
what actually ships the update to existing users.

## Dry run (no credentials)

```bash
scripts/release.sh
```

Produces `dist/Pathem-<version>.dmg` and `dist/appcast.xml` locally. Without
`DEVELOPER_ID` the app is ad-hoc signed (Gatekeeper will warn); without the
Sparkle key the appcast enclosure has no `edSignature` (clients would reject the
update). Useful for checking the DMG contents and the appcast shape before doing
the real thing. `PUBLISH=1` is required to touch GitHub, and it refuses any of
these unsigned states. Delete stale dry-run fragments in `dist/appcast.d/` before
publishing; an unsigned item in the appcast also blocks a publish.

## How the pieces fit

- `scripts/package.sh` owns app building, inside-out codesigning (never
  `--deep`), and notarization. It bundles the app, the `pathem-afc` device
  helper, and Sparkle; it does **not** bundle `pathem-ext-example` (a reference,
  not a shipped feature).
- `scripts/release.sh` owns everything downstream of a built app: the publish
  preflight and gate, DMG, Sparkle signature, appcast, GitHub publish.
- `scripts/verify-release.sh` is the read-only artifact check the publish path
  runs; you can also run it by hand on any `.app`.
- `test/release/publish_gate_test.sh` exercises every publish refusal in a
  throwaway repository with a fake `gh` (part of `make ci`).
- Sparkle's tools (`generate_keys`, `sign_update`) come from its resolved
  artifact bundle under `.build/artifacts`; a `swift build` fetches them.
- Release artifacts live in `dist/` (gitignored). The appcast is served from
  GitHub Releases, never from the repo tree.
