# Environmental verification

`make e2e-env` covers boundaries that ordinary CI cannot assume are present. Its contract is
deliberately different from `make ci`:

- **PASS** means the named boundary was present and the real operation succeeded.
- **SKIP** means hardware, permission, an opt-in scope, or a public-network capability was absent.
- **FAIL** means a boundary was supplied or could be created hermetically, but behaved incorrectly.

The default run creates only disposable local fixtures. It verifies a real APFS secondary volume,
disk-image attach/eject, 25,000-file enumeration, shell/external-command semantics, permission-state
reporting, loopback FTP and SFTP CRUD through Pathem's actual subprocess providers, and read-only
hardware discovery. Scratch state is removed on exit; credentials are neither required nor logged.

## Opt-in checks

These variables enable boundaries that cannot be manufactured safely on every machine:

| Variable | Effect |
|---|---|
| `PATHEM_SPOTLIGHT_LIVE=1` plus `PATHEM_SPOTLIGHT_SCOPE=/path` | Creates, imports, finds, and removes one uniquely named file inside an indexed disposable scope. |
| `PATHEM_PROVIDER_TREE_ROOT=/path` | Compares the fast and Foundation listings of a provider-backed directory without changing it. |
| `PATHEM_ICLOUD_EVICTION_LIVE=1` plus `PATHEM_ICLOUD_ROOT=/path` | Creates a unique iCloud Drive fixture, waits for upload, evicts it, moves it through `FileOperations`, verifies bytes/source removal, and cleans up only that fixture. |
| `PATHEM_DHT_LIVE=1` | Queries the public mainline DHT for a known public-domain torrent. |
| `PATHEM_ROUTER_LIVE=1` | Requests a temporary high TCP port through NAT-PMP and then UPnP. Unsupported routers report SKIP. |
| `PATHEM_TRANSMISSION_DAEMON=/path` plus `PATHEM_TRANSMISSION_REMOTE=/path` | Starts a disposable Transmission daemon, then downloads its real payload through Pathem's peer engine and verifies both bytes and the peer client identity. |

The runner also reports whether external storage, a USB mobile device, and an SMB/NFS/WebDAV mount
are visible. Detection is read-only: destructive storage tests and writes to user-owned shares are
never inferred from the presence of hardware.

The minimum-supported-OS build is the existing manual/PR GitHub Actions workflow on `macos-15`.
Keeping it off `push` is intentional: macOS minutes are billed at a higher multiplier, while
`make ci` remains the local trunk gate.

## Human sign-off (never automated into a false pass)

Before a public release, a human records each item as pass/fail with the OS version and build:

- VoiceOver: navigate every file view, both panes, the sidebar, toolbar, transfer queue, torrent
  drawer, settings, conflict confirmation, and Full Disk Access guide without using the pointer.
- Localization: a native speaker for French, German, Spanish, Japanese, and Simplified Chinese
  reviews the first-run flow, menus, toolbar, sidebar, settings, error messages, plurals, truncation,
  and the entries in `docs/L10N_GAPS.md`.
- Exploratory UX: complete copy/move/rename/trash/undo, drag among every destination, remote transfer,
  archive edit, torrent/magnet add, terminal use, and quit/relaunch recovery with real user pacing.
- Hardware: repeat the relevant runner checks with an iPhone/iPad, external APFS disk, and mounted
  network share when those integrations are part of the release claim.

Missing human or hardware sign-off remains visibly pending; it is not converted to PASS by a
successful unit test.
