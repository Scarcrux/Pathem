# Commandem plugin: `commandem pathem`

Opens, reveals or previews a registered project's files in Pathem from Commandem.
`commandem open --pathem <project>` already opens a project's root folder; this
plugin reaches inside it.

```sh
commandem pathem Pathem                    # open the project folder
commandem pathem Pathem Sources/Pathem     # open a subfolder
commandem pathem Pathem Package.swift      # reveal (select) a file
commandem pathem Pathem --preview README.md
commandem pathem --changed                 # current project: reveal the newest uncommitted change
commandem pathem Pathem src/x.swift --print  # show the command without running it
```

The plugin only does the Commandem part: it finds the project (by name, or the
one containing the current directory) and keeps relative paths inside it. The
action itself is Pathem's own CLI, which works without Commandem:

```sh
pathem-cli <path>          # opens a folder, reveals a file
pathem-cli changed [dir]   # reveals the newest uncommitted change, lists the rest
```

so `commandem pathem Pathem src/x.swift` runs `pathem-cli <project>/src/x.swift`
and `--changed` runs `pathem-cli changed <project root>`. `--preview F` runs
`pathem-cli preview <abs F>`.

Install: copy `commandem-pathem` to `~/.config/commandem/plugins/` and make it
executable. It needs Python 3 and Pathem; it calls the bundled
`Pathem.app/Contents/MacOS/pathem-cli` (override with `PATHEM_CLI`), or hands a
`pathem://` URL to Launch Services when the CLI is missing (`--changed` needs
the CLI). Project names match like Commandem's own
(exact, unique prefix, unique substring); relative paths stay inside the project.

Tests: `python3 -m unittest discover -s test -p commandem_plugin_test.py`.
