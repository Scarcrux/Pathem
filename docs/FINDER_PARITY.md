# Finder parity gaps (Mission 53 task 10)

Design and acceptance criteria, written before implementation. Owner request 2026-11-16:
Claude designs and supervises, Sonnet agents implement, one unit at a time. Scope chosen by
the owner from a read-only gap audit of the same date: all of F1 to F5 below.

Most of what the task names already exists (Compress, Compress to 7-Zip, Quick Look, Make
Alias, Show Original, Show Package Contents, colour tags, sidebar Eject). These units cover
only what the audit found missing or inconsistent.

## Rules for every unit

- One unit, one or more small commits, then stop and report. Nothing lands without review.
- Red first: write the check, show it failing on the current code, then fix.
- A menu item that does not apply is hidden, not merely disabled, unless Finder itself
  shows it disabled. A command's enabled rule and its menu's hide rule must agree.
- New user-visible strings go through `L("key", "English")` with entries in all five
  non-English catalogs; `python3 scripts/l10n_lint.py` must pass.
- A new alert, sheet, panel, popover or menu is a new presentation site: update
  `test/transient_inventory.json` so `python3 test/transient_inventory.py` passes.
- Do not add confirmations or safer defaults to actions the user explicitly invoked.
  Pathem is a power-user tool (owner ruling 2026-11-15).

## F1. One empty-space menu in every view, View Options, and Eject

Evidence: right-clicking empty space in list view builds a separate reduced menu
(`FileListController.makeBackgroundMenu`: Copy Path, Copy Name, New Folder, New File, Paste,
and Empty Trash in the Trash). Icon, gallery, column and tree views show the shared menu
with View, Group By and Sort By. `BrowserViewController+BackgroundMenuUITests.swift` reads
the shared menu even in list view, so the difference is untested. "View Options…"
(`view.options`, Cmd-J) is in the View menu only. Eject (`files.ejectVolume`) is in the
Tools menu and the sidebar only, and its enabled rule (volume is not `/`) is looser than
the sidebar's `volumeIsEjectable`.

Change:
- List view's empty-space menu offers the same entries, in the same order and with the same
  state, as the other views' empty-selection menu, plus what it has today: Copy Path, Copy
  Name, New Folder, New File, Paste, Get Info (of the folder), View, Group By, Sort By,
  View Options…, and Empty Trash in the Trash. Prefer sharing the construction over a
  second hand-written list.
- "View Options…" appears in the empty-space menu of all five views.
- Eject appears in the empty-space menu when the folder shown is on an ejectable volume,
  and in the file menu when the single selected item is an ejectable volume's root. It is
  hidden otherwise. `files.ejectVolume`'s enabled rule uses the same test as the sidebar.

Acceptance:
- The background-menu harness opens the real empty-space menu of each view (for list view,
  the one `makeBackgroundMenu` returns) and asserts one shared expected list of entry ids.
  Red before the change for list view; green after for all five.
- A check that the Eject entry is absent for a folder on the boot volume and present for a
  fixture the test controls (a mounted disk image the test creates and detaches; never a
  real external disk). If creating a disk image is not possible in the harness, test the
  rule function directly and say so.
- Existing suites still pass: `PATHEM_BACKGROUND_UI_TEST`, `PATHEM_FINDER_UI_TEST`, smoke.

## F2. iCloud: Download, Remove Download, Keep Downloaded

Evidence: `files.download` exists and is in the file menu but is never hidden, so it shows
greyed out for ordinary local files. Remove Download exists as "Offload to iCloud"
(`files.offload`, File menu only). Keep Downloaded does not exist.

Change:
- File menu entries, Finder's wording: "Download Now" for items that are in iCloud and not
  local; "Remove Download" for items that are in iCloud and local. Both hidden for anything
  that is not an iCloud item. The File menu's existing item is renamed to match.
- Keep Downloaded: first establish, from Apple's documentation and the SDK headers, whether
  a public API exists to pin an iCloud Drive item so it stays local. If one exists,
  implement it with a checkmark state. If none does, do not approximate it with private API
  or `brctl`; report that, with the evidence, and leave it out.

Acceptance: a rule-level test for which of the three entries shows for each of: a plain
local file, a dataless iCloud item, a downloaded iCloud item, a mixed selection. Real
iCloud behaviour is environmental and is not claimed by this unit.

## F3. Services, and F5. Quick Actions (investigate first)

Hypothesis to test before writing code: AppKit adds Services and Quick Actions to a context
menu by itself when the menu allows context-menu plug-ins and the responder that owns the
selection implements `validRequestor(forSendType:returnType:)` and
`writeSelection(to:types:)` for file URLs. If that holds, F3 and F5 are one small change in
the file views, not two features. A read-only investigation reports first; this section is
rewritten from its findings.

## F4. Tags: create, rename, recolour, delete

Evidence: seven colours and a fixed list of named labels can be applied; there is no way to
apply a tag with a new name, and no way to rename, recolour or delete one.

Change (to be detailed after F1 to F3): apply a free-form named tag with a colour to the
selection; remove any tag from the selection; an editable tag list in Settings. Renaming or
deleting a tag updates the files that carry it, found through Spotlight; when the index is
unavailable (it is switched off on the development Mac) the user is told which part could
not be done, and nothing is reported as complete that was not.
