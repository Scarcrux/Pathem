# Shared static SDK compatibility: evidence and acceptance

Trigger: a real engine recompile during the background-menu slice exposes seven
pre-existing warning fingerprints (eight declarations) missing from cached logs.
Swift 6.4 says `nonisolated(unsafe)` is unnecessary for SDK-Sendable DateFormatter,
NSRegularExpression and CIContext constants. The strict gate rejects that log:
19 owned, 12 known, seven unrecognized; no baseline exception is added.

History (`e605748`) records an older CI SDK compatibility purpose. Preserve that
fallback for compiler <6.4; use compiler-checked constants on the locally verified
6.4+ path. Both branches initialize the same values once, through common factories
where needed. No new unchecked conformance, warning suppression, locks or per-call
formatter/context allocations. The older SDK branch is preserved, not reverified
on an unavailable toolchain; no all-SDK portability claim.

Acceptance before the final inventory sample/full CI:

- Force an otherwise unused `PATHEM_WARNING_INVENTORY` condition to invalidate
  compiler-command caches; it must have no feature branch. Log actual compiler
  delivery and owned-source recompilation, not merely a successful warm build.
- Require successful compilation and exact warning-gate acceptance without changing
  exceptions. The actual rejected seven-fingerprint log is the red control. Retain
  known pending diagnostics, do not claim warning-free source.
- Run the real ordering, cloud-list parsing, batch-rename, process-list, metadata and
  image suites in full local CI. Modern initialization/configuration must behave as
  before. Package the release product and verify signature, launch and window checks.
- Keep legacy fallback, current SDK proof and live Vision/native image acceptance
  separate. No system preferences, keychain, permission grants or installation.

Current incremental modern builds no longer emit the seven redundant-unsafe
fingerprints and pass the unchanged warning gate. Forced inventory and full CI
remain pending.

## Forced inventory: failed acceptance and amended scope

The forced build completes in 53.51 seconds, with 460 compiler command lines
containing the delivered condition. The unchanged gate fails: 28 owned, 14 known,
14 newly discovered, zero unparsed. The seven redundant-unsafe fingerprints are
absent, but the prior inventory was demonstrably incomplete. This is a failed
inventory criterion, not a green run.

Two fingerprints are array C-string deprecations in UPnP/VPN address parsing.
Before the next sample, require bounded UTF-8 decoding through the first NUL,
including empty, padded address, unterminated, non-ASCII and malformed UTF-8 controls.
Keep pointer-based C-string uses unchanged; no live network traffic is needed.

The other twelve are SecureTransport APIs in the unchanged iOS usbmux byte-channel
bridge (confirmed in HEAD). Replacing its transport requires paired-device TLS
acceptance unavailable in this deterministic slice; it is not safe to treat the
compiler's Network.framework suggestion as a drop-in fd wrapper. Amend the gate
inventory to retain **only these twelve exact file/message fingerprints** as
explicit pending migration debt, with a roadmap task. No source suppression or
new redundant-unsafe exceptions. This expands the measured debt, not coverage or
compatibility claims. A new message/path or an unparsed warning must still fail.

CI's debug build now receives a unique, otherwise unused
`PATHEM_CI_WARNING_INVENTORY_` condition on every invocation, so a warm cache cannot
hide newly exposed owned-source diagnostics. Before scaling to CI, require the five
C-string controls, unchanged eight gate controls, no production conditional using
either inventory prefix, and a fresh sample gate verdict: zero new/unparsed after
the narrowly documented TLS debt addition. Full CI must actually compile owned
sources before its gate, and still exercise normal debug and release builds.

The bounded-decoding sample passes 5/5 controls. Its actual recompilation log passes
the amended gate: 26 owned/26 exact known/zero new/zero unparsed. Eight gate controls
pass; inventory-condition prefixes have no production/test feature branches. Full
CI is now justified; its fresh inventory and complete test verdict remain pending.

## Final verification

Full local `make ci SWIFTPM_FLAGS='--build-system native --jobs 2'` exits zero.
The fresh debug build recompiles 321 Pathem/PathemEngine/TorrentKit source entries
and completes in 68.08 seconds. Its gate reports 26 exact known fingerprints and
zero new/unparsed. Debug plus release union reports 27 exact known, zero new and
zero unparsed. The original forced log still fails on its two C-string fingerprints
after the TLS debt inventory amendment: no blanket file/API exemption was added.

Unit verification: 15 XCTest tests; Swift Testing reports 779 cases across 161
suites. Five opt-in live tests (FTP/SFTP, public DHT, Transmission interoperability)
are explicitly skipped, not environmental acceptance. Debug E2E reports 61 passed,
one explicit browser-capture opacity skip, zero failures; packaged current-host
release E2E reports 9/9, including signature, launch and visible window. This is
integrated workbench verification alongside the background-menu slice, not proof
of universal architectures, older SDKs, native popup tracking or paired-device TLS.
No installation, publication, keychain changes, permission grants or live
provider/storage writes.
