# Pathem extension developer guide

This draft describes the private Phase 1 extension runtime. Pathem enables it only
when started with `PATHEM_ENABLE_EXTENSIONS=1`. The public SDK and extension
catalog are separate work.

## Build and install

Build a standalone macOS executable. The reference implementation is
`Sources/pathem-ext-example/main.swift`. Distribute a Developer ID Application
signed, notarized executable and its manifest. Use the Hardened Runtime and a
secure timestamp when signing. Submit the distribution archive to Apple's
notary service. The host checks the executable's signature against the Developer
ID and notarization requirement, so approval is unavailable when the ticket
cannot be verified. Keep the executable self-contained because the host stages
a private copy of the executable for each invocation.

Create one folder per extension in
`~/Library/Application Support/Pathem/Extensions/`. Put the executable and
`manifest.json` in that folder. The executable path is relative, and symlinks
are rejected. Use a unique reverse-DNS ID. The optional `teamID` is an assertion
that must match the verified signature. The signed executable supplies the
developer and team identity shown in Settings.

```json
{
  "id": "org.example.pathem.wordcount",
  "name": "Word Count",
  "version": "1.0.0",
  "executable": "word-count",
  "contributes": {
    "commands": [
      {"id": "count", "title": "Count Words", "handler": "wordCount"}
    ]
  }
}
```

Commands are the supported contribution in Phase 1. Pathem does not load
manifest columns, viewers, menus, keybindings, or theme files.

In **Settings → Extensions**, review the signed developer, team, and declared
commands before selecting **Approve**. Approval binds the full manifest to the
verified executable's code-directory hash and a digest of its bytes. A changed
manifest or executable requires approval again. **Disable** clears approval.
**Remove** moves the extension folder to the Trash and clears its approval.

## Protocol v1

Pathem first starts the helper with a `__hello` request. Reply with `ok: true`,
`protocolVersion: 1`, the same `requestID`, and the capabilities array
`["commands"]`. The hello exchange carries no browsing context. After validating
the reply, Pathem starts a fresh process for the actual command. Both exchanges
use one UTF-8 JSON line on stdin and one on stdout. Send logs to stderr.

Each request includes `protocolVersion`, a UUID `requestID`, `capabilities`,
`handler`, and `arguments`. Command requests may include `context` with the
current folder and selected local paths. Only use the paths necessary for that
command. Each reply repeats the version, request ID, and capabilities. A
success includes `ok: true` and an optional JSON `result`. A handler error
exits successfully with `ok: false` and a `failure` object containing `code`,
`message`, and `recoverable`. A nonzero exit is a process failure.

Each exchange is limited to one MiB of request data and one MiB of stdout,
64 KiB of stderr, with at most 32 nested JSON containers. The normal wall-clock
limit is ten seconds per exchange. Pathem also limits CPU time and writable file
size in the launcher. Progress and cancellation messages are reserved for a
later protocol.

## Process permissions

Pathem tests responsible-process attribution before it loads any third-party
extension. If the macOS behavior cannot be verified, the extension runtime
stays disabled. The launcher uses a private macOS responsibility API and
separates the helper from Pathem's Full Disk Access attribution. It starts the
helper with a temporary working directory, an explicit HOME, PATH, and LANG,
and only the intended standard streams. On timeout or overflow it terminates
the process group. A helper can have ordinary user-level access and can leave
its process group. This is not a sandbox or a defense against an already
approved helper acting with its own access.

First-party helpers such as curl, SFTP, ADB, and AFC continue to act on Pathem's
behalf. Pathem plans a supported XPC boundary before a public SDK rollout.
