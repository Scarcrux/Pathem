# Contributing to Pathem

Thanks for your interest. Pathem is a native macOS file manager written in Swift
(AppKit, with a Foundation-only engine). It is MIT licensed.

## Reporting things

- **Bugs and feature requests:** open an issue using the templates. Include your
  macOS version and Pathem's build (Pathem > About Pathem shows the build and
  commit).
- **Translations:** eleven of the twelve UI languages are machine-drafted. If a
  phrase reads wrong, use the Translation feedback issue template, or see
  [docs/TRANSLATIONS.md](docs/TRANSLATIONS.md).
- **Security problems:** never in a public issue. See [SECURITY.md](SECURITY.md).

## Pull requests

Outside pull requests will open after the first public release, once the terms
for contributions are settled. Until then, please open an issue first to discuss
a change.

## Building and testing

```sh
swift build            # the engine and the app
swift test             # the engine test suite
swift run Pathem       # launch a debug build
make ci                # everything CI runs, including the GUI end-to-end suites
```

You need macOS 15 or later and Xcode's Swift toolchain. Tests prefer real files in
temporary folders over mocks, and GUI checks run against a demo workspace, never
your own files. Style is enforced with `swift-format` (see `.swift-format`), and
commits follow Conventional Commits.

## Where things are

- `Sources/PathemEngine`: enumeration, file operations, search, remote backends
  (no AppKit).
- `Sources/Pathem`: the app.
- `Sources/TorrentKit`, `Sources/PathemTerminal`: the torrent engine and terminal.
- `docs/`: see [docs/README.md](docs/README.md) for what each document is.
- `DESIGN.md`: the architecture and the reasoning behind it.
