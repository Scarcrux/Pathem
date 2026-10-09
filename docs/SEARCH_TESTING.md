# File search acceptance criteria

Trigger: users expect keyword matching in filenames or contents with an explicit location;
the old Cmd-F silently ranked folder entries by semantic similarity and had no result UI tests.

Criteria written before implementation validation:

- Filename mode finds a mixed-case keyword in a real filename; a content-only match must fail.
- Contents mode finds a keyword in a neutral-named text file; a name-only match must fail.
- This Folder and a selected other folder stay within that root. The subfolder toggle is honored.
- This Mac routes to Spotlight with the selected filename/content predicate. Hermetic tests assert
  routing with a fixture backend; they do not claim that the live OS index is complete.
- Empty/clear, no matches, loading, backend error, result limits and skipped reads are distinguishable.
- Debounced typing, mode/scope changes, close and reopen cannot adopt stale results or actions.
- Enter and arrow keys choose a real result; Reveal selects it after async navigation, without
  replacing the underlying pane's listing while the user is still typing. Open uses normal file opening.
- Toolbar and Cmd-F reach the same search UI; column mode is supported; command search stays separate.
- A real-window layout check and screenshot show readable controls and result columns at minimum size.

Negative controls (name-only, content-only, out-of-scope and deliberately delayed stale results)
must traverse the same engine/controller as their passing counterparts. Matching only a success
marker, accepting an empty fixture, or asserting a helper without exercising the controls fails
the design. The deterministic sample must pass these criteria before running the ordinary broader suite.

Validation notes: the initial sample correctly failed Cmd-F because saved-search registration
removed every `search.*` command, including the built-in entry point. Ownership-scoped cleanup
fixes the demonstrated cause and the regression now passes. The first 32 real-window checks and
8 hermetic engine tests passed, including all positive/negative matching controls. Live capture
was attempted twice and `screencapture` exited 1; cached AppKit rendering also produced invalid
black/white controls and was rejected. Scripted layout assertions pass; visual screenshot
approval remains unproven and is not counted as a passed criterion.

Final local CI: 2026-10-09 `make ci` passed localization in all six catalogs, 9 XCTest tests,
762 Swift Testing tests, 18 debug product scenarios (including 39/39 search UI checks and the
existing 49/49 interaction checks), and 9 signed release-package/launch checks. No public
release, installed-app replacement, or keychain changes were performed.

Direct folder search excludes hidden entries and package internals, does not follow symbolic links,
and does not read online-only files. Contents mode scans UTF-8 text up to 32 MiB per file and merges
scope-checked Spotlight document matches (PDF/Office and installed importers); omissions and an
unavailable document index are reported. Whole-Mac contents search uses Spotlight's indexed text.
Live Spotlight, OS folder-picker interaction,
and default-app interoperability remain environmental, not hermetic coverage claims.
