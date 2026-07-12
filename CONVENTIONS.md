# Conventions

Shared standards for every project in the constellation (the tools commandem
coordinates). Drop this into a new repo, delete the language rows that don't
apply, and link it from the project's `CLAUDE.md`. The **Standing
directives** section is propagated automatically by `commandem brief` — you
don't hand-copy it; it's listed here only so you know what your project
gets.

> New project, one-time setup:
> ```bash
> commandem init <path>     # scaffold commandem.toml (the manifest contract; see SPEC.md)
> commandem add <path>      # register it with commandem
> commandem brief --apply   # inject the Standing directives into the project's CLAUDE.md
> pre-commit install      # wire the format/lint/test hooks
> ```

---

## Commit & workflow

- **[Conventional Commits 1.0](https://www.conventionalcommits.org/):**
  `type(scope): subject` — imperative mood, subject ≤ 72 chars.
  - Types: `feat` `fix` `refactor` `chore` `docs` `test` `style`.
  - Breaking change: append `!` (`refactor!: …`) **and** a
    `BREAKING CHANGE:` footer paragraph.
  - Body explains **why**, not what (the diff shows what); wrap at ~72.
- **Trunk-based:** all work commits direct to `master`. Feature branches
  only for genuinely speculative spikes that may not land. **No
  force-push to `master`** (history is append-only once pushed).
- **Small, atomic commits** per module/feature — split when in doubt.
- **Commit identity:** authored as **`Scarcrux`** + your GitHub noreply
  email (never a work/edu address). Set it locally:
  ```bash
  git config user.name "Scarcrux"
  git config user.email "<your-github-noreply-email>"
  ```
- **No `Co-Authored-By: Claude …` trailer** — single-author repos; AI
  assistance is implicit, not in the Git author field.
- **No `--no-verify`.** If a hook fails, fix it and make a new commit.

## Code style

- **Stdlib-first.** Add a dependency only when stdlib genuinely doesn't fit
  and a documented trigger fired (note the trigger in code/docs).
- **Errors flow up with context**, then translate to a friendly message +
  exit code at the boundary (Go: `fmt.Errorf("context: %w", err)`).
- **No em-dashes in user-facing strings** — use periods or "(detail)".
- **Match the surrounding code**: comment density, naming, idiom. Read like
  the file you're editing.
- **Format + vet on commit** (see the language table) — never hand-format.

## Testing

- **Local-only, no CI.** No GitHub Actions. Tests run via the pre-commit
  hook + manual `<test command>`.
- Prefer **integration-via-real-I/O** (temp dirs, real subprocess, an
  in-process HTTP test server) over heavy mocking.
- Add a **contract / probe test** for any external CLI or API you depend on
  (it pins the wire shape so an upstream change fails loudly, not silently).
- Coverage is a means, not the goal: cover the **load-bearing logic**; don't
  pad glue/printing to move a number.

## Commandem integration (optional but recommended)

- **`commandem.toml`** at the repo root is the machine contract (mode +
  commands + conventions). See commandem's `SPEC.md`. Re-run `commandem add .`
  after editing it.
- **Health checks** (deployed projects): add a `[[check]]` block
  (`url` / `expect_status` / `expect_body` / `ssl_expiry_days`, multiple =
  multi-endpoint) so `commandem monitor` watches it.
- **Link checks:** expose a hook and set
  `links_check_command = "<cmd>"` (exit 0 = clean, non-zero = broken links);
  `commandem links` runs it on a schedule and routes breakage into the one
  notification stream.

## Standing directives (auto-injected by `commandem brief`)

*Listed for awareness — `commandem brief --apply` writes these verbatim into
your CLAUDE.md; don't duplicate them by hand.*

- **iCloud hygiene.** Keep only regenerable/churny dirs out of iCloud via
  the `.nosync` trick; source dual-backs-up to iCloud + GitHub harmlessly.
  - For `.git` (load-bearing, non-regenerable): use git's **gitdir pointer
    file**, NOT a symlink (iCloud evicts symlinks across reboots):
    `mv .git .git.nosync && printf 'gitdir: .git.nosync\n' > .git`. Add
    `*.nosync/` to `.gitignore`.
  - For regenerable dirs (e.g. a build dir): the symlink trick is fine, but
    the build script must **self-heal** the symlink before each build.
  - A `* [0-9].*` filename (e.g. `chat 2.go`) is an iCloud conflicted copy
    — the real file is in git; sweep the duplicate.
- **OrbStack** over Docker Desktop for any containers (drop-in, far lower
  resource use, native Rosetta on Apple Silicon).

## Constellation philosophy

- **Right language for the runtime:** Go for hot-path CLIs (sub-10ms cold
  start, single binary); Python for daemons (cold-start paid once via
  launchd). They talk via JSON, not shared code.
- **Stay narrow.** Each tool earns its complexity; resist creep into a
  do-everything app. If a feature pulls the tool past its stated scope,
  reject it (or record the scope evolution honestly).

---

## Language quick-reference

Delete the rows that don't apply; wire the format/lint hook in
`.pre-commit-config.yaml`.

| Stack  | Format + vet (pre-commit)        | Test command            | Notes |
|--------|----------------------------------|-------------------------|-------|
| Go     | `gofmt -w` + `go vet ./...`      | `go test ./...`         | Go 1.25+, stdlib-first; pin `toolchain` in go.mod |
| Python | `ruff --fix` + `ruff format`     | `pytest`                | Install CLIs with `pipx --editable`, not pip-into-venv |
| Swift  | `swift-format` (or SwiftFormat)  | `swift test`            | SwiftPM, no Xcode project unless the build genuinely needs it |
| Node/TS| `prettier` + `eslint --fix`      | `vitest` / `node --test`| stdlib/`node:` first; lockfile committed |
