# Search surfaces (Mission 53 task 13)

Design and acceptance criteria, written before implementation. Owner request 2026-11-16:
Claude designs and supervises, Sonnet agents implement, one unit at a time. Scope chosen by
the owner from a read-only gap audit of the same date: all of S1 to S4 below.

The Cmd-F panel (`GlobalSearchController`: filename and content modes, scope, loading,
no-results, error and truncation states, keyboard, races, all five views) is implemented
and covered by about 465 checks. These units bring the other search surfaces up to it.

## Rules for every unit

- One unit, small commits, then stop and report. Nothing lands without review.
- Red first: write the check, show it failing on the current code, then fix.
- A search that could not run, or whose results were cut off, says so. An empty list must
  never be the only sign of a failure or a cap.
- New strings through `L("key", "English")` in all five non-English catalogs;
  `python3 scripts/l10n_lint.py` must pass. New presentation sites go in
  `test/transient_inventory.json`.
- Embedding and indexing stay off the main thread. Tests use an injected embedder or a
  fixture backend, never the real on-device model.

## S1. Find in Files reports failures and its cap

Evidence: `ContentSearch.search` returns an empty array when the search tool fails, and
stops at 2000 matches without saying so; the window then shows "0 matches" or "2000
matches".

Change: the engine returns a result that distinguishes matches, a failure (with the tool's
message) and truncation. The window shows "Search failed: …" for a failure and adds
"Results limited to 2000; narrow your search." when capped. Replace All must refuse to run
on a truncated or failed result set's assumptions: it reports how many files it changed, as
today, and says when the preceding search was capped.

Acceptance: engine tests for a failing tool invocation, an over-cap result and a normal
one; the Find in Files UI checks (`PATHEM_FIND_IN_FILES_SAMPLE`) extended to assert the
two new status texts, red before the change.

## S2. Semantic search shows what it is doing

Evidence: semantic search re-ranks the active pane. It shows nothing while the index
builds, a failed index build looks the same as no matches, the 5000-item cap is silent, and
in column view, on a remote pane or over smart results it only beeps.

Change: a visible "Indexing…" then "Ranking…" state; "Semantic search could not index this
folder: …" on failure; "Only the first 5000 items were indexed." when capped; and where it
cannot run, a status message saying why, in place of the beep.

Acceptance: UI checks with an injected embedder covering each state and each refusal, plus
clear and reopen: after clearing, the pane's listing, selection and scroll position are
what they were before the search. Red before the change where the state is missing today.

## S3. Semantic as a third mode in the Cmd-F panel

Evidence: filename and content are modes of one panel with a scope control; semantic is a
separate command with a different surface and a fixed, hidden scope.

Change: the panel's mode popup gains a third entry for semantic search. It honours the
panel's scope for "This Folder" (with or without subfolders, within the index cap) and
"Other Folder…"; for "This Mac" the mode is unavailable and says why. Results appear in
the panel's list with the same Open and Reveal behaviour, and the states from S2. The
existing "Semantic Search This Folder…" command opens the panel in that mode. The pane is
no longer re-ranked in place, so nothing about the pane changes until the user reveals.

Acceptance: the search UI suite's mode, scope, state, keyboard, race and
viewport-preservation groups run for the semantic mode as they do for the other two, with
an injected embedder. The default mode stays filename.

## S4. Small items

- Keyboard Open: Return still reveals; Cmd-Return (and Cmd-O) opens the selected result.
  Check in the keyboard group for all five views.
- The toolbar Search button's title and tint reflected only a semantic query. After S3 no
  search changes the pane, so the button shows no query state; before S3 lands, leave it.
