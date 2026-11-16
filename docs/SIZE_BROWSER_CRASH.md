# Size Browser row attachment crash

The Unit 2 full native run aborted in group 6 at the first loaded Size Browser
row. AppKit's NSGenericException identifies row.width and rows.width with no
common ancestor; the stack is makeRow -> render -> load. Raw native exit -6 and
incomplete coverage remain preserved at
.build/transient-full-qualification-v1/clean-de-full-mounts-g6.native.log.
The installed app was not involved; this was the private fixture executable.

render previously evaluated makeRow before adding its returned view, but
makeRow activated a cross-view width constraint immediately. The fix creates
the same row, attaches it, then activates the same width constraint. No widths,
fonts, checks or user behavior are relaxed.

The existing M43 regression drives a real owned nonempty folder, short and
255-character names, both host sizes and appearances, three presentations,
and the loaded-row transition. The corrected German run completes all eight
cells and exact cycle/content receipts: native 256/332 with only geometry and
ambiguity pairs (20 distinct). No crash, missing treatment or isolation error.
Cancel, Return observation, responder restoration and accumulation checks pass.
Both owner defaults are unchanged, private domain cleared, demo root removed.
Evidence: .build/transient-size-browser-fix-probe.log and matching M43 JSON/raw.
The full matrix must run again on the changed binary before Unit 2 READY.
