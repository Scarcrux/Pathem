# Releasing Pathem

Pathem ships as a notarized, direct-download `.app` that auto-updates through
[Sparkle](https://sparkle-project.org) (EdDSA-signed appcast). It is not on the
Mac App Store (the sandbox can't grant Full Disk Access). This is the full
release runbook.

The two scripts do the work:

- `scripts/setup-sparkle-key.sh` — one-time EdDSA update-signing key setup.
- `scripts/release.sh` — build, sign, notarize, DMG, appcast, publish.

Everything is gated: any step whose credential is missing is skipped, so a bare
`scripts/release.sh` still produces a DMG and appcast in `dist/` for inspection.
A real, installable release needs the credentials below.

There is also a CI path: `.github/workflows/release.yml` runs the same
build/sign/notarize/appcast flow on a pushed `v*` tag, using repo secrets (the
Developer ID certificate, notary credentials, and `SPARKLE_PRIVATE_KEY`). Use
whichever fits: the scripts here for a local release, the workflow for a
tag-triggered one. The one-time Sparkle key setup below is shared (CI reads the
private key from the secret; a local run reads it from your Keychain).

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
   - build a universal (arm64 + x86_64), Hardened-Runtime-signed bundle
     (`scripts/package.sh`), notarize and staple it;
   - wrap it in `dist/Pathem-<version>.dmg` with a drag-to-Applications target;
   - sign the DMG with your Sparkle key;
   - regenerate `dist/appcast.xml` (newest release first, each item pointing at
     its own tag's download URL);
   - create the GitHub release `v<version>` and upload the DMG + appcast.

4. Push the tag:

   ```bash
   git push && git push --tags
   ```

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
the real thing. `PUBLISH=1` is required to touch GitHub.

## How the pieces fit

- `scripts/package.sh` owns app building, inside-out codesigning (never
  `--deep`), and notarization. It bundles the app, the `pathem-afc` device
  helper, and Sparkle; it does **not** bundle `pathem-ext-example` (a reference,
  not a shipped feature).
- `scripts/release.sh` owns everything downstream of a built app: DMG, Sparkle
  signature, appcast, GitHub publish.
- Sparkle's tools (`generate_keys`, `sign_update`) come from its resolved
  artifact bundle under `.build/artifacts`; a `swift build` fetches them.
- Release artifacts live in `dist/` (gitignored). The appcast is served from
  GitHub Releases, never from the repo tree.
