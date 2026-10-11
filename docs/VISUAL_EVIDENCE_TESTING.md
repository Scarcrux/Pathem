# Trustworthy capture evidence: preregistration

Trigger: nonempty PNG checks cannot discriminate a real UI from black/white,
transparent, corrupt or clipped cached renders. An E2E process must also finish
successfully, not merely print a success marker before failure or timeout.

## Criteria written before sampling

- Use ImageIO's real PNG decode path for both controls and captured surfaces. Require
  a complete single-image PNG ending in IEND, dimensions at least 64x64 and at most
  8192x8192, and bounded input. PNG termination follows the
  [W3C PNG specification](https://www.w3.org/TR/png-3/).
- Downsample to 128x128 RGBA. At least 95% of samples must be opaque, luminance range
  at least 40, at least eight quantized RGB colors, and at least four of sixteen tiles
  must have a luminance range of 24. These are necessary sanity criteria, not a
  perceptual comparison or proof of readability/accessibility.
- When an expected pixel size is supplied it must match exactly. A clipped-dimension
  fixture must fail. Same-size clipping inside an otherwise valid raster is **not**
  proven detectable; real-control geometry assertions cover some of that boundary.
- Good gradient PNG passes; black, white, transparent, corrupt, truncated and cropped
  PNG controls fail through the exact same decoder/checker. Report actual rejection
  reasons per control. Broken design: a bad control passes, or only file size/existence
  is checked.
- Real representative cached captures: settings, sidebar, browser flow and conflict
  content. Validate independently; no new golden image is automatically approved.
  A rejected cached capture is explicitly untrusted evidence; native visual
  acceptance is SKIP, not PASS. Corrupt/missing output fails the renderer pipeline.
  Only the observed browser-flow transparency boundary may skip. Validated settings,
  sidebar and custom conflict fixtures must fail on unusable pixels. Report-policy
  controls: good passes; blank/transparent strict fixtures fail; explicitly allowed
  transparency skips; flat or missing output still fails even with the allowance;
  a nonzero exit after PASS fails. A blanket SKIP for any bad cached image is broken.
- E2E completion controls run through the production verdict predicate: successful
  PASS and allowed SKIP pass; PASS then nonzero exit, PASS then timeout, final FAIL,
  and missing result fail. Actual command exit/timeout must be delivered and logged.
  A malformed PASS token, PASS embedded in a FAIL detail, and SKIP when not allowed
  must also fail.
  Existing `RESULT: PASS: explanation` is a valid legacy success format and needs
  its own passing control; a colon-delimited description is not part of the token.
- Before the full bounded matrix, sample light/English/default labels and
  dark/German/long labels. Actual effective appearance, preferred language and
  action labels must be logged by the rendered view, not inferred from flags.
  Then exercise light/dark x English/German x default/long labels (eight cells).
  Unsupported appearance must exit 64 without producing a PNG. These are cached
  content fixtures, not native popover chrome or an all-locale coverage claim.

## Confidence boundary

Pixel sanity and geometry are not native appearance approval. Cached AppKit render
does not include all materials/window chrome/popup placement. Physical keyboard,
foreground menu tracking, native capture permissions, reduced-motion/accent and
all-locale golden comparisons remain pending. Do not grant TCC, change system
preferences, publish images or silently accept baseline updates in this batch.

## Verdict

Initial pixel sample passes 7/7 controls with actual rejection reasons. Existing
settings/sidebar PNGs pass sanity; browser-flow PNG fails opacity (0.746) despite
having nonempty bytes and visible pixels. Conflict content passes sanity. None are
human-approved goldens.

Production completion predicate initially fails 3/6 controls: accepts PASS then
exit 7, PASS before final FAIL, and PASS before a delivered timeout (exit 142).
Predicate now requires successful exit and the final anchored RESULT line. First
standalone sample was stopped by the toolchain preflight (Swiftly instead of Xcode);
no controls ran until rerun with Xcode PATH. Corrected initial six controls pass;
three additional malformed/disallowed result controls are mandatory in CI.

Sample delivery passes: the real content logs light/Aqua, English, Replace at
500x112, and dark/DarkAqua, German, long labels at 500x196. Both decoded PNGs pass
sanity (opaque 0.994/0.996, luminance range 179/187, 14/13 detailed tiles). Inspected
the two content PNGs; this does not approve native popover chrome or window placement.
The design can reject bad inputs and logs its treatment, so the bounded eight-cell
matrix can proceed. Full local CI remains pending.

First full CI passes 15 XCTest + 772 Swift Testing and the eight-cell matrix, but
fails the Gate A result parser: exit 0 and bounded cell counts were delivered, yet
its existing `RESULT: PASS: explanation` format was rejected by the new whitespace
token delimiter. Debug totals: 59 pass, one cached-opacity SKIP, one parser failure;
packaging did not run. Add that real format as a differing passing control and
accept colon as a delimiter, without accepting PASSIVE or embedded PASS in FAIL.

Second full CI passes 15 XCTest + 772 Swift Testing, 60 debug checks, one explicit
browser-opacity SKIP, and nine packaged checks. Final policy review then reproduces
three failures in seven classification controls: blanket skips would hide strict
blank/transparent fixtures and a blank render even with the transparency allowance.
Scope that allowance to browser-flow opacity only. The ten completion controls and
seven classification controls run together through the production predicates.

Final verdict: 7/7 decoded-image controls, 10/10 completion controls and 7/7 report
classification controls pass. Actual eight-cell matrix delivery and pixel sanity
pass; invalid appearance exits 64 and writes no PNG. Final `make ci` passes 15
XCTest + 772 Swift Testing, 60 debug harness checks and nine packaged checks.
Browser cached opacity remains 0.746 and explicitly SKIP; no native golden is
approved. All other unusable stable captures now fail rather than silently skip.
The warning gate also tests owned instrument paths (8/8 controls). Final builds are
incremental: zero emitted owned warnings is not a warning-free source claim; the
last fresh inventory still has 15 exact remaining fingerprints.
