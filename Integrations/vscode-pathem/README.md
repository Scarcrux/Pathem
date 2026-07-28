# Reveal in Pathem

A tiny VS Code / Cursor extension that reveals the current file or folder in
[Pathem](https://github.com/Scarcrux/Pathem), the native macOS file manager.

VS Code's built-in **Reveal in Finder** targets Finder by identity and can't be
redirected, so this adds a parallel **Reveal in Pathem** command to:

- the Explorer context menu (right-click a file or folder),
- the editor tab context menu (right-click a tab),
- the editor context menu (right-click in the text), and
- the command palette (`Reveal in Pathem`).

It shells out to the `pathem` command-line tool that Pathem installs, and falls
back to Pathem's `pathem://` URL scheme when the CLI isn't found.

## Requirements

- macOS with Pathem installed.
- The `pathem` CLI on disk (Pathem installs it at `/usr/local/bin/pathem` or
  `/opt/homebrew/bin/pathem`). If it lives elsewhere, set **Pathem: Cli Path** in
  settings. Without the CLI, the extension uses the `pathem://` URL scheme, which
  works as long as Pathem is installed.

## Install

From a packaged `.vsix`:

```bash
code --install-extension pathem-reveal-0.1.0.vsix
# Cursor:
cursor --install-extension pathem-reveal-0.1.0.vsix
```

To build the `.vsix` yourself: `npx @vscode/vsce package` in this folder.

## Settings

- `pathem.cliPath` — absolute path to the `pathem` CLI. Leave empty to auto-detect.
