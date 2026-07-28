// Reveal in Pathem: a tiny VS Code / Cursor extension that shows the current file
// or folder in Pathem, the native macOS file manager. VS Code's built-in "Reveal in
// Finder" targets Finder by identity and can't be redirected, so this adds a parallel
// "Reveal in Pathem" command to the Explorer context menu, the editor tab menu, and
// the command palette. It shells out to the `pathem` CLI, falling back to Pathem's
// pathem:// URL scheme when the CLI isn't on disk. Plain CommonJS, zero dependencies.

const vscode = require("vscode");
const { execFile } = require("child_process");
const fs = require("fs");

// Where Pathem installs its CLI (Homebrew Intel vs Apple-Silicon prefixes).
const CLI_CANDIDATES = ["/usr/local/bin/pathem", "/opt/homebrew/bin/pathem"];

function resolveCLI() {
  const configured = vscode.workspace.getConfiguration("pathem").get("cliPath");
  const candidates = configured ? [configured, ...CLI_CANDIDATES] : CLI_CANDIDATES;
  for (const path of candidates) {
    try {
      if (path && fs.existsSync(path)) return path;
    } catch (_) {
      // ignore unreadable candidates
    }
  }
  return null;
}

// The file-system path to reveal: the right-clicked resource if present, else the
// active editor's document (only real files, not untitled/virtual docs).
function targetPath(resource) {
  if (resource && resource.fsPath) return resource.fsPath;
  const editor = vscode.window.activeTextEditor;
  if (editor && editor.document && editor.document.uri.scheme === "file") {
    return editor.document.uri.fsPath;
  }
  return null;
}

function revealViaURL(fsPath) {
  const url = "pathem://reveal?path=" + encodeURIComponent(fsPath);
  execFile("/usr/bin/open", [url], (error) => {
    if (error) {
      vscode.window.showErrorMessage("Pathem: couldn’t reach Pathem. Is it installed?");
    }
  });
}

function reveal(resource) {
  const fsPath = targetPath(resource);
  if (!fsPath) {
    vscode.window.showWarningMessage("Pathem: no file to reveal.");
    return;
  }
  const cli = resolveCLI();
  if (!cli) {
    revealViaURL(fsPath);
    return;
  }
  execFile(cli, ["reveal", fsPath], (error) => {
    if (error) revealViaURL(fsPath); // CLI failed (e.g. app not running): try the URL scheme
  });
}

function activate(context) {
  context.subscriptions.push(vscode.commands.registerCommand("pathem.reveal", reveal));
}

function deactivate() {}

module.exports = { activate, deactivate };
