# Security Policy

Pathem is a non-sandboxed macOS app that runs with Full Disk Access and can act
on files anywhere on your Mac. Security reports are taken seriously, and this
page explains how to report a problem and what to expect.

## Supported versions

Fixes land in the latest release and on the `main` branch. Please confirm a bug
still reproduces on the current release before reporting it.

| Version        | Supported |
| -------------- | --------- |
| Latest release | Yes       |
| `main`         | Yes       |
| Older releases | No        |

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Use one of these private channels instead:

- GitHub private reporting: open the repository's Security tab and choose
  "Report a vulnerability". This keeps the report between you and the maintainer.
- Email: security@pathem.app

Helpful things to include:

- The Pathem version (Pathem > About Pathem) and your macOS version.
- Steps to reproduce, and what an attacker could do with the issue.
- A proof of concept if you have one, plus any relevant logs or crash reports.

## What to expect

- An acknowledgement within three business days.
- An honest read on severity and a rough timeline for a fix.
- Updates while the fix is in progress, and a heads up before any public
  disclosure.
- Credit in the release notes when the fix ships, if you would like it. There is
  no paid bounty program.

Please allow a reasonable amount of time for a fix before disclosing publicly.

## Scope

In scope:

- The Pathem app and its helper processes (the out-of-process torrent daemon and
  the device helper used for iOS access).
- The auto-update path. Updates are delivered through Sparkle and signed with an
  EdDSA key, so reports about update integrity are welcome.
- The remote backends (S3, WebDAV, SFTP, FTP) and how credentials are stored and
  used.

Out of scope:

- Issues that require an already-compromised Mac, or physical access to an
  unlocked machine.
- Vulnerabilities in macOS itself, or in third party software that Pathem talks
  to, rather than in Pathem's own code.

Thanks for helping keep Pathem and its users safe.
