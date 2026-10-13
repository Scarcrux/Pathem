# Always Open With: extension-less files

Trigger: owner report, 2026-10-13. Using Always Open With on a `.env` file did not open
it after Set, and later opens did not use the chosen app.

Evidence, gathered before any change, read-only:

- A file named `.env` has `pathExtension == ""` and content type `public.data`, the
  root type every data file conforms to. Its default app is TextEdit.
- `openers.json` holds no file, folder or type rules, so the owner chose the
  system-wide scope.
- That scope calls `NSWorkspace.setDefaultApplication(at:toOpen: public.data)` and
  discards the completion error. LaunchServices has no handler for `public.data`
  afterwards, so the change never took, and nothing told the owner.
- Had it worked, it would have changed the default for every file macOS does not
  recognize, not just `.env`.
- Set only saves a rule. Nothing opens the file, while Finder's Always Open With does.
- Session scope is keyed by extension, so a session choice for one extension-less file
  would apply to every extension-less file (`Makefile`, `LICENSE`, `.gitignore`).

No test calls `setDefaultApplication` for real or launches an app: a DEBUG recorder
captures the open and system-default requests instead.

Criteria written before implementation:

- O1 Set opens the file with the chosen app, for the file, folder, filename and session
  scopes. Cancel opens nothing.
- O2 For a file with no extension, the third scope reads "All files named “<name>” (in
  Pathem)", saves a filename rule to memory and `openers.json`, and makes no
  system-default request.
- O3 A later open of the same file, and of another file with the same name in a
  different folder, resolves to the chosen app through `applyOpen`, the function
  double-click uses.
- O4 Negative control: a different extension-less file (`Makefile`) does not resolve to
  that app, for either the filename scope or the session scope.
- O5 Files with an extension keep the system-wide scope, and it requests the specific
  type, never `public.data`, `public.item` or `public.content`. If the system refuses,
  the owner sees an error and the file is not opened as if it had worked.
- O6 An older `openers.json` without a filename map still loads all its other rules.
- O7 Discrimination: with the session key reverted to the bare extension (a temporary
  control build), O4's session check must fail. If it passes, the check does not test
  the bug.

What would mean the design is broken: any test path reaching the real
`setDefaultApplication`, or O4 passing on the control build.

## Validation (2026-10-13)

`PATHEM_OPENER_UI_TEST` passes 51/51 in an isolated config root, with every open and
system-default request recorded instead of performed.

- O1 PASS. File, folder and session scopes each record `open <file> with <app>` right
  after Set (`set-opens-file-with-choice-0/1/3`). Cancel records nothing.
- O2 PASS. For `.env` the third scope reads "All files named “.env” (in Pathem)",
  saves `byName[".env"]` to memory and `openers.json`, makes no system-default request,
  and opens the file with the chosen app.
- O3 PASS. `applyOpen` on `other/.env` resolves to the chosen app.
- O4 PASS. `Makefile` resolves to the system default under both the filename rule and
  a session choice made for `LICENSE`.
- O5 PASS for the request: `fixture.txt` with the system-wide scope records
  `system-default <app> public.plain-text`, then opens the file with that app. The
  premise also holds on a real file: `.env` is `public.data`, which `isGeneric`
  refuses. Not exercised: the error alert when LaunchServices actually refuses a
  change, because that needs a real system change.
- O6 PASS. Engine tests: an older `openers.json` without `byName` loads its other
  rules, and the round trip is exact (782 Swift tests total).
- O7 PASS, plus two more controls, each a temporary build reverting one fix:

| Control | Result | Checks that went red |
|---|---|---|
| Session key reverted to the bare extension | 50/51 | `session-extensionless-not-other-names` |
| `applyOpen` ignores filename rules | 49/51 | `env-set-opens-with-choice`, `env-rule-reaches-same-name-elsewhere` |
| Set no longer opens the file | 47/51 | `set-opens-file-with-choice-0/1/3`, `env-set-opens-with-choice` |

Get Info's "Open with" now uses the same helper: it refuses generic types with an
explanation and reports a refused change instead of discarding the error. No
automated test covers Get Info; that path was checked by reading the code only.

The owner's earlier attempt left nothing behind to undo: no LaunchServices handler for
`public.data` and no saved Pathem rules.
