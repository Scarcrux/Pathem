# Design: a superuser file manager for macOS

> Name: **Pathem** (decided). It reads as "Path 'em": plain, friendly, and
> easy to say, which is why it was chosen over the earlier "Pathom" (whose
> meaning few people decode). The naming analysis below is the historical
> Pathom screen; its domain/trademark facts are for `pathom.*` and have NOT
> been re-run for `pathem.*`. TODO before any branding spend: confirm
> `pathem.app` availability (RDAP) and run USPTO TESS clearance (Classes
> 9 & 42). Repo directory: `scarcrux-pathom`.

Status: **design phase**. This document records the competitive analysis, the
language/architecture decision, and the MVP cut. It is the output of a
multi-agent research pass (5 research agents → 3 architecture proposals →
judge → adversarial critic) whose load-bearing technical claims were verified
on this machine (macOS 26.5.1, arm64, Swift 6.3.2).

---

## 1. Vision

A deeply **native**, **high-performance** macOS file manager, the spiritual
successor to Windows' **Directory Opus**, aimed past Cocoatech's **Path Finder**
and far past Finder. "Superuser" means the file view is a configurable
workspace, not a fixed window: dual-pane, tabs, saved layouts, per-folder
formats, find-as-you-type, batch rename, and (eventually) a command/scripting
system. Built by a solo dev, free and open source (MIT), no subscription, on-device,
privacy-forward.

Per CONVENTIONS.md: right-language-for-runtime, stdlib-first, **stay narrow**
(each feature earns its complexity), single notarized binary, no bundled
runtime.

---

## 2. Competitive analysis

### Directory Opus (Windows, GP Software): the thing to live up to
Not a prettier Explorer; a programmable workspace. The features that make it
"superuser" and are worth cloning:

- **Lister + Layouts**, the core mental model. A *Lister* is a file window
  (single/dual pane, optional tree + viewer + metadata pane); a *Layout* is a
  saved snapshot of one or more Listers (tabs, panes, tree state, columns,
  toolbars) you reopen in one click. Define an environment per task, snap into
  it instantly. **This is the biggest leap over Finder.**
- **Dual/multi-pane + heavy tabbed browsing** (source-left/dest-right; dozens
  of persistent, lockable tabs).
- **Find-As-You-Type (FAYT)**, any keystroke opens a bottom field: Find /
  Filter (live wildcard narrow) / Command (`>`) / DOS (`?`), with an `=`
  expression evaluator (`=size>100kb`). Collapses navigation, filtering,
  ad-hoc commands, and metadata queries into one keyboard-driven field.
- **Flat View**, collapse a whole tree into one operable listing; sort /
  filter / rename / de-dup across all levels at once.
- **Per-folder / wildcard folder formats**, the view auto-reshapes to
  content (images → thumbnails + EXIF columns; music → tags + bitrate).
- **Advanced batch rename**, regex + macros + metadata-driven naming + live
  preview + saveable presets. A bulk-rename utility built in.
- **File Collections + saved searches + duplicate finder**, virtual folders
  you can act on across origins.
- **Command system + ActiveX scripting + button/command editor**, the true
  differentiator: nearly every behavior is a scriptable command.

There is **no macOS version and never has been** (Windows/AmigaOS only). v13
moved to an "upgrade subscription" (perpetual license, paid updates).

### Path Finder (Cocoatech): correction to a stale assumption
**Important:** Path Finder is **not** discontinued and **not** subscription-
*only* anymore. As of mid-2026 it's actively developed (v26.x, date-based
numbering, Apple-Silicon native). Pricing now offers **three** paths: 30-day
trial, **a perpetual-style license key is back** (~$30), *and* a subscription
($2.95/mo or $29.95/yr); also on Setapp. So "it's subscription-based" is no
longer the whole story, but the subscription pivot is exactly what burned its
base, and that resentment is real market energy to capture.

Feature depth is admired: dual-pane + one-click copy/move, **Drop Stack**
shelf, tabs, FolderSync compare/sync, integrated terminal, a modular
drawer/shelf (Info, Attributes, Permissions, Preview, Tags, Git, Hex,
Terminal), batch rename, tagging, hidden-files toggle, archive browsing.
Reputation is mixed (~3.8/5): subscription backlash, v8 rewrite regressions,
recurring stability bugs, weak support, **non-native feel**, macOS-version lag.
**Lesson: copy the depth; avoid the subscription, the bloat, and the
non-native feel.**

### The wider market (mid-2026) and the white-space
- **ForkLift 4** (Swift, ~80% SwiftUI, one-time $20–70), the benchmark to
  beat. Best-in-class remote/transfer/sync. Actively developed, Tahoe-native
  (4.6.4, Jun 2026). **The MVP competes against ForkLift's maturity, not
  against Finder.**
- **QSpace / QSpace Pro** (native AppKit, up to 12 panes, one-time + paid
  extensions), strong, but a-la-carte upsells raise trust questions.
- **Marta** (pure Swift, Lua-customizable, free), beloved but ships
  erratically (pre-1.0, long gaps).
- **Nimble Commander** (C++ core, GPLv3, fast), steep Norton-Commander UX.
- **Commander One** (dated), **TotalFinder** (dead, needs SIP off),
  **HoudahSpot** (search specialist, not a manager), **Tokie** (folders as
  Notion-style DBs, non-native), AI organizers (Sortio/Mane/Filex, search
  utilities, not managers).

**Genuine white-space (no single app combines these):**
1. Truly native + fast + modern (Liquid-Glass-era) UI, **and**
2. AI-native **on-device semantic / natural-language search**, **and**
3. Rich **metadata/tags as a first-class sortable column-database**, **and**
4. Great transfer/sync, **with a perpetual, no-subscription license.**

Each competitor wins one axis and loses the others. That's the opening.

### Lead differentiator: integrated LLM support (decided)

Per the market analysis above, the #1 white-space is AI: no native, fast Mac
file manager has integrated LLM support. This is Pathem's chosen north-star
differentiator. Candidate capabilities (sequenced *after* the engine is stable):

- **Semantic / natural-language search**, "the contract I edited last spring,"
  "screenshots with errors", over an on-device content index.
- **Natural-language file ops**, describe a batch rename / move / filter and
  preview the resulting operations before applying (always undoable).
- **Content-aware organize & rename**, suggest names/folders from file
  contents; semantic dedup.
- **Ask-about-this**, summarize, extract from, or compare selected files.

Constraints to settle in a dedicated LLM design phase (not now):

- **Privacy-forward.** Prefer on-device where viable; for any cloud call,
  explicit scoped consent, never silently upload file contents. This is itself
  a trust differentiator vs. the AI-organizer crowd.
- **Provider.** Default to the latest Claude models (Opus 4.8 / Sonnet 4.6 /
  Haiku 4.5) for cloud; evaluate on-device models for privacy/cost. Use the
  `claude-api` skill when we design/build this.
- **Cost & latency.** Index incrementally, cache, and keep LLM calls off the
  hot path. Gate the whole feature behind the stable core (stay narrow).

#### LLM engine strategy (decided after research)

"Bundle a local LLM?" → **partly, decouple search from generation.**

- **Search = embeddings, not an LLM.** A tiny embedding model (Apple
  `NLContextualEmbedding`, 0 bundle bytes / ~100MB on-demand asset; or a bundled
  `bge-small`, MIT, ~30-65MB) + a local vector index (`sqlite-vec`, 384-dim,
  int8/binary). Runs on ~100% of Macs incl. Intel. **This is the AI MVP** and
  the broad-reach headline; it never hallucinates a file reference.
- **Generation = Apple Foundation Models (DECIDED; primary, 0 bundle bytes).** macOS 26's
  built-in ~3B on-device model. `@Generable` constrained decoding yields a
  *typed* FileOperationPlan we preview + user confirms + OUR code executes, the
  LLM never touches the filesystem (safe for destructive ops). Sweet spot =
  summarize / extract / classify = features 2/3/4.
- **Generation fallback (capability-detected; build the seam now, defer the
  impl).** When Apple Foundation Models is unavailable, fall back to a small
  Apache-2.0 model, but mind the runtime split: **`mlx-swift` is
  Apple-Silicon-only** (covers AS Macs with Apple Intelligence off), while
  **Intel Macs need `llama.cpp`** (CPU inference, ~a few tok/s, slow).
  Downloaded on first run, never bundled. Search is unaffected:
  `NLContextualEmbedding` runs on Intel, so Intel users keep semantic search
  (the "basic AI") for free regardless. Build the `Embedder`/`Generator`
  protocol + `SystemLanguageModel.default.availability` detection now; defer the
  llama.cpp Intel-generation path until demand (Intel is end-of-line, macOS 26
  was the last Intel release).
- **Cloud (optional, consented):** Claude (Opus 4.8 / Sonnet 4.6; Haiku 4.5 for
  cheap classification) for large-corpus compare/summarize beyond the on-device
  ~4K context. Per-action consent; send only the selected file/region. Build
  with the `claude-api` skill. (Note for build time: Claude 4.6+ uses adaptive
  thinking, not `budget_tokens`; use `output_config.format` + strict tools;
  Haiku 4.5 is 200K context.)
- **License rule:** bundle only OSI-permissive weights (Apache-2.0 / MIT: Qwen3,
  SmolLM2, Phi-4-mini, bge-small, Model2Vec). **Avoid Llama (Community License)
  and Gemma (custom terms)**, open-weight, not OSI, with UI/redistribution
  strings.
- **AI is progressive enhancement.** Core file manager works without it
  (glob/regex batch ops, metadata search, manual templates).
- **Caveats:** Foundation Models needs Apple silicon + macOS 26 + Apple
  Intelligence enabled (Intel excluded; Tahoe adoption ~52% near-term);
  **~4K on-device context** (macOS 26.4, retrieve-then-feed only the relevant
  passages, pre-flight every prompt with `tokenCount()`, handle
  `.contextWindowExceeded`; don't stuff whole files).

> Fact-checked (2026): architecture verified sound. Licenses, model sizes,
> hardware gating, and Claude model IDs all confirmed. Corrections applied:
> on-device context is ~4K (not 8K). Additional notes: at true
> millions-of-files scale use binary/int8 vectors or USearch (HNSW), sqlite-vec
> brute-force suits ~100k-500k chunks; don't pin the fallback to one model, pick
> the latest Apache-2.0 ~3-4B at build time; read embedding dimensionality from
> the API at runtime and store the model id+revision with the index (any swap
> forces a full re-index).

---

## 3. Language & architecture decision

### Decision: **Swift**, one language, one toolchain, one debugger.
AppKit is the load-bearing UI framework; **SwiftUI is a deliberate, scoped
sugar layer for low-cardinality chrome only** (inspector, preferences,
favorites sidebar, command palette, dialogs, via `NSHostingView`).

**Why Swift wins** (judge scored it 45 vs 44 vs 33):
- Only option that gets **both** maximal macOS-26 nativeness **and** the proven
  100k+ row scroll ceiling, while staying single-toolchain for a solo dev with
  no CI.
- Day-one access to every Apple framework (QuickLook, Liquid Glass,
  toolbar/sidebar, tagging, FSEvents).
- Already the constellation's stack row (SwiftPM, swift-format, swift test, no
  `.xcodeproj` unless the bundle/Liquid-Glass build genuinely needs it).
- Reaches the decisive performance primitive (`getattrlistbulk`) through a tiny
  C shim, **exactly as Rust would.**

### The non-negotiable: the file list is **view-based `NSTableView` /
`NSOutlineView`**, not SwiftUI.
Verified: SwiftUI `List`/`Table` does **not** virtualize on macOS and collapses
well below target (~900ms per selection change at ~1000 rows; auto-diff can't
be disabled). AppKit view-based tables with genuine cell recycling are the
documented ceiling for 100k+ rows at 120fps. The file list **is** the product,
so it gets the proven control.

### Alternatives, and why rejected
- **Pure SwiftUI file view**, fatal: no virtualization at scale. (SwiftUI is
  fine for chrome only.)
- **Rust core + Swift UI**, scored 33. FFI is mechanically sound (verified: a
  Rust staticlib linked into SwiftPM returned a value across the C ABI), but
  Swift hits the *same* `getattrlistbulk` syscall through the *same* shim, so
  Rust buys **~0 MVP performance** while imposing a permanent two-toolchain
  tax. Rust's real wins (jwalk/rayon recursion, Tantivy index) are all
  deferred. Per stdlib-first + "documented trigger," it's the **deferred
  escape hatch**, not the start. (A real fragility was reproduced live: the
  cargo cache built into a *sibling project's* path-derived bucket
  `~/Library/Caches/cargo-targets/hearthsim/`.)
- **Rust + GPUI/egui**, **Tauri**, **Electron/Qt/Flutter**, all forfeit native
  AppKit controls / accessibility / QuickLook / Liquid Glass and/or add a heavy
  runtime. Direct contradiction of "most native + highest performance + single
  binary." (Electron also has an open 2026 issue causing system-wide lag on
  macOS 26.)

### Verified benchmarks (this machine)
- `getattrlistbulk` returned **924 entries from `/usr/bin` in one 128KB-buffer
  syscall** (`ls /usr/bin | wc -l` = 924 ✓).
- Parallelizing single-dir enumeration ≈ **10% gain** (syscall-bound) → do
  **not** thread single-dir enum; reserve modest parallelism for recursive
  scans.
- macOS 26 `NSTableView` header-overlap regression is real → fix with a 1pt top
  inset.
- Finder "Put Back" only reliably works for the **first** trashed item per
  process → **ship our own undo stack.**
- `copyfile` `COPYFILE_CLONE` is near-instant **intra-volume only** → silently
  falls back to full byte-copy cross-volume.

---

## 4. Architecture

Two in-process layers in one binary, separated by a **plain-struct boundary**
(no FFI, no serialization):

**Engine** (Swift, Foundation-light, **zero AppKit dependency**, `swift test`-
able against real temp dirs):
1. **Enumerator**, `getattrlistbulk`, 128KB buffer, requests *only displayed
   attributes*, emits fixed-layout `FileEntry` value-type structs into a
   contiguous array (no `NSURL` in the loop).
2. **DirectoryModel**, owns the per-pane snapshot; sorts/filters in place into
   an index vector.
3. **Watcher (two-tier)**, always-on **FSEvents** (FileEvents flag, persisted
   event ID for replay) for the tree, plus **DispatchSource/kqueue** on
   *currently-visible* dirs only; mandatory `MustScanSubDirs`/Dropped subtree
   re-scan (with its **own** debounce/coalescing, a build/unzip can thrash).
4. **OpService**, off-main bulk ops; `copyfile COPYFILE_CLONE` same-volume;
   direct POSIX xattr access; **app-owned `NSUndoManager`** undo stack.
5. **SearchService (dual-path)**, `MDQuery` for instant indexed results **plus**
   a raw walker as Spotlight-independent ground truth. (Benchmark `fts_open`/
   `fts_read` vs `getattrlistbulk` for the *recursive* path before committing , 
   `fts` often wins on local APFS trees.)

**UI**: hand-tuned view-based `NSTableView` (Details) / `NSOutlineView` (tree),
fixed row height, real view recycling, **lazy outline data source** (proxy
children so expanding a 100k-child node never asks for all children), reading
directly from the index vector.

**Grafted from the runner-up proposals:**
- SwiftUI shell (via `NSHostingView`) for low-cardinality chrome only.
- One shared `@Observable` store as the single UI truth (selection, sort,
  filter, FAYT, active layout), strictly one-directional flow:
  engine → store → UI, and UI intent → store → engine.
- **Layouts/columns/toolbar config as versioned Codable JSON** (schema-version
  field + migration path from v1), the DOpus "customize everything" ethos,
  human-editable, shareable, stdlib-first.

**Build**: SwiftPM package → engine + app; thin script assembles `.app` +
`Info.plist` + codesign (the one accepted bundling carve-out); swift-format +
swift test; Developer ID + notarization; **non-sandboxed**, user-granted Full
Disk Access.

---

## 5. Performance strategy

1. `getattrlistbulk` + 128KB buffer + displayed-attrs-only → a 100k-file
   listing goes from 100k+ stalls to tens of ms.
2. Value-type struct array + index-vector sort/filter (no object graph), read
   by recycled cells → only visible+overscan rows exist → 120fps on ProMotion.
3. Lazy outline data source → dodges the expand-asks-for-every-child trap.
4. Don't parallelize single-dir enum (~10%); reserve parallelism for recursive
   scans.
5. Cold start: single native binary, no runtime, no FFI init; first paint gated
   on one `getattrlistbulk`. (Target sub-100ms *interactive*, note: a windowed
   AppKit app will **not** hit the constellation's CLI-class sub-10ms; that
   target doesn't apply here.)
6. Thumbnails: instant `NSWorkspace` type icons first → `QLThumbnailGenerator`
   for visible+overscan only, cancel-on-scroll, bounded `NSCache` LRU keyed by
   URL+mtime+size, progressive quality; **never block scroll**; budget for the
   QuickLook daemon stalling on malformed files (when-not-if on a whole-disk
   browser).
7. Same-volume copy via `COPYFILE_CLONE`; xattrs/tags via direct POSIX.

**Proof gates (before any chrome):**
- **Gate A**, scroll a **synthetic 1M-entry directory** smoothly (validates
  virtualization).
- **Gate B**, expand a synthetic node with **100k+ direct children** with no
  main-thread stall (the lazy `ProxyItem` outline data source is the single
  riskiest piece of AppKit in the app; it gets its own milestone).

---

## 6. MVP cut (stay narrow)

1. Single-window file view on the `getattrlistbulk` enumerator + view-based
   `NSTableView`, **pass Gates A & B first** (make-or-break).
2. Core navigation: `NSPathControl` **editable address bar**, descend/back/
   forward/parent, native keyboard nav + type-select.
3. Two-tier watcher with `MustScanSubDirs`/Dropped re-scan (correctness gate,
   not optional).
4. Sortable columns (name, size, kind, dates) on the struct array; instant
   hidden-files toggle.
5. Off-main file ops w/ progress: copy (clone same-volume), move, rename, new
   folder, **New File**, delete-to-Trash + **app-owned undo**, gated behind a
   **conflict-resolution policy** (overwrite / keep-both / skip / apply-to-all;
   cross-volume move = copy→verify→delete, never delete on partial failure;
   interruption recovery).
6. Async thumbnails done right + spacebar `QLPreviewPanel`.
7. A single keyboard-driven **FAYT** field that live-filters the in-memory
   struct array (no Spotlight dependency, nearly free given the engine holds
   the snapshot).
8. **Dual-pane (minimal)**, ✅ **in MVP.** Two side-by-side file views
   (source/destination) with one-key copy/move between them; it's category
   table-stakes (every competitor ships it). Full multi-pane, tabs, and saved
   Lister/Layout workspaces stay deferred.
9. Non-sandboxed notarized bundle + first-run Full Disk Access prompt.
10. **App update mechanism**, wire **Sparkle** (EdDSA appcast) now; generate/
    secure the signing key. Blocking infra, not a feature (no MAS = no built-in
    update channel).
11. **Accessibility as acceptance criteria**: VoiceOver row/rotor announcement
    + keyboard-only nav over the custom table/tree (recycled cells +
    `NSHostingView` islands routinely break this unless tested).
12. **Pre-release smoke checklist** (real file, since no CI): VoiceOver pass;
    copy/move/rename/trash + undo on APFS *and* a non-APFS/case-sensitive
    volume; xattr/tag round-trip; FSEvents resync under an unzip; thumbnail
    daemon stall handling.
13. Lightweight crash diagnostics (local crash-log surfacing or opt-in
    reporter), whole-disk access + unsafe-pointer syscall parsing + no CI +
    bus-factor-of-one.

**Explicitly deferred** (each must earn past "stay narrow" on a stable
engine): tabs, Lister/Layout workspaces (then add as Codable JSON), flat view,
FAYT `=` evaluator, scripting/command system, batch-rename engine (high-
goodwill, add early as a showcase), collections/saved searches, archive-as-
folder, FTP/SFTP, inspector/modules, labels/ratings, **integrated LLM support**
(the lead differentiator; see §2, gate behind a stable core), and **any
Rust subsystem** (Tantivy index / jwalk), gated behind a measured profiling
trigger + a contract/probe test on the new ABI boundary (pin struct layout,
fail loudly on drift; pin `CARGO_TARGET_DIR` per-project).

> Honest framing: the MVP-as-cut is a *faster, more native Finder*, an engine
> proof. It is **not yet** a reason to leave ForkLift. The differentiators
> (dual-pane workspaces, semantic search, metadata-DB columns, no-subscription
> positioning) are what make it a competitor; sequence them deliberately.

---

## 7. Naming

`macfinder` is out (contains Apple's "Finder" mark; also Apple disallows "Mac"
in third-party product names, so "Mac Explorer" is out, and "Power Explorer"
sits in Microsoft's "Power*"/"Explorer" family and is generically weak).

**Decision: Pathem** (preliminary screen, **not** legal clearance):

| Name | Why | TM risk | Notes |
|------|-----|---------|-------|
| **Pathem** ✅ chosen | reads as "Path 'em": plain, friendly, sayable | **LOW (historical screen was for "Pathom")** | no software/app collision found in the original screen. Domain facts here are historical for `pathom.*` (`pathom.app` was RDAP-404 available); `pathem.app` / `getpathem.com` availability is NOT yet verified. `.app` is HTTPS-only (free TLS). |
| **Bursar** | "keeper of the stores/keys" → custody + control | LOW | cleanest real-word lane found in a 2nd naming round (no software collisions). Recorded only as a fallback if Pathem is ever revisited. |

Two naming rounds ran (coined words, then recognizable real words). The
tradeoff accepted: a coined word is the most ownable/defensible class of mark
but carries no built-in meaning, so brand/positioning must teach it ("Pathem , 
a file manager for Mac"). No real word cleared the file-manager lane as cleanly
as Pathem without either a collision or weaker defensibility, so Pathem stands.

Before branding spend: confirm `pathem.app` / `getpathem.com` availability
(not yet checked) and run a full USPTO TESS knockout search in Classes 9 & 42.

---

## 8. Open decisions

1. ~~**Name**~~, **Decided: Pathem.**
2. ~~**Dual-pane in MVP?**~~, **Decided: yes (minimal, two panes, one-key
   copy/move). Multi-pane/tabs/Layouts deferred.**
3. ~~**Update channel / Mac App Store?**~~, **Decided: direct-only,
   non-sandboxed (user-granted Full Disk Access), updates via Sparkle (EdDSA
   appcast, key generated at v0). MAS is skipped, the App Sandbox cannot
   grant Full Disk Access, which would gut the whole-filesystem "superuser"
   reach the product exists for.**
4. ~~**First differentiator after the engine**~~, **Decided: two-launch plan
   (see §9).** Launch 1 = native engine + minimal dual-pane (the speed is the
   demo); Launch 2 = on-device semantic search (the §2 north-star), kept free in
   the OSS build, months later. Each launch is its own Show HN + blog post.

## 9. Business model, license & launch (decided)

Goal reframed: the primary objective is **reach + reputation** (GitHub stars,
attention, job prospects); revenue is strictly secondary. Two independent,
adversarially fact-checked research passes (growth strategy; relicensing
options) converged on the plan below and confirmed the stars goal and the career
goal are *aligned*, not in tension.

### License: MIT (decided)
- Permissive OSI licensing is the category norm and the growth funnel: every
  native-Mac / file-manager breakout is permissive (Files, nnn, superfile,
  Ghostty, Stats, Maccy). MIT keeps Pathem eligible for Homebrew, distros, and
  awesome-lists and kills the "that's not real open source" derail that hijacks
  every source-available launch thread.
- `LICENSE` is committed (MIT, © 2026 Scarcrux). The only defensible alternative
  is **Apache-2.0** (explicit patent grant, marginally better for the
  on-device-AI code); verdict is **keep MIT**. Protect the brand via
  **trademark, not the license**.

### Relicensing reality ("can we change from MIT later?")
- As **sole copyright holder** you can release *future* versions under any terms
 , but only while you remain sole copyright holder.
- **Already-published MIT versions are permanent and forkable forever**
  (Terraform→OpenTofu, Redis→Valkey). Relicensing-away is a "rug pull" that
  detonates goodwill and invites a fork of your last MIT commit. **Last resort,
  not a plan.**

### Day-one actions to preserve every option (before the repo goes public / before any external PR)
1. **Relicensing-grant CLA** via CLA-assistant-lite (GitHub Action, signatures
   in-repo): contributor keeps copyright but grants you a broad, irrevocable,
   sublicensable license that *explicitly includes the right to relicense /
   dual-license*. **DCO alone is insufficient.** Single load-bearing action , 
   one external PR merged without it fragments copyright and blocks any relicense.
2. **Keep sole, provably-clean copyright**, no copied third-party/GPL snippets
   in the MIT tree; until the CLA tooling is live, hold or rewrite external PRs.
3. **Trademark "Pathem"**, use `Pathem™` now (common-law, free); budget a USPTO
   registration (~$350/class DIY) at launch; add a short Trademark Usage Policy.
   A worst-case MIT fork then still can't ship as "Pathem."
4. **One IP/OSS lawyer consult** to finalize the CLA wording (not legal advice).

### Monetization (orthogonal to the license, secondary)

**Decision: GitHub Sponsors tip jar now + a planned open-core "Pathem Pro"
later.** Strict sequencing: ship the free MIT flagship and earn the launch stars
FIRST; Pro comes months later as a *separate closed-source* superset, never by
paywalling anything that was already free. Sponsors stays a garnish (~$0–100/mo;
MonitorControl ≈ $120/mo at 33k stars); Pro is the real lever ($1–3k/mo good
case, Rectangle/AltTab template).

**Pathem Pro scope, iron rule: the free core stays a genuinely great Finder
replacement, and on-device semantic search (the §2 headline differentiator)
stays FREE forever. Pro is net-new *additive* power, never a downgrade of free.**
- **FREE (MIT core):** fast browsing, dual-pane, tabs, navigation, core file
  ops, QuickLook, hidden files, basic batch rename, AND on-device semantic
  search.
- **PRO (~$9.99 one-time, closed):** saved Lister/Layout workspaces; advanced
  batch-rename presets + scripting/automation; multi-pane (3+); folder
  sync/compare; FTP/SFTP/cloud remote browsing; a cloud / cross-device variant
  of semantic search; deep theming/customization.
- **Structure:** free core in the public MIT repo; Pro a *separate private repo*
  depending on the core as a Swift package. The core's **relicensing-grant CLA**
  (§ day-one actions) is what makes building closed Pro on top of community
  contributions legal, so the CLA is a prerequisite for Pro, not optional. Sell
  Pro direct via Paddle/Gumroad (~95% kept) ± a paid MAS SKU; offer a trial.
- **Career note:** Pro is a revenue *side-track*. For the stated job target
  (ML Engineer / Quant Researcher) the priority is the finance-research
  flagship, not Pathem revenue, build Pro only once free Pathem has real
  traction.

The detail below records the broader option space; the decision above is the plan.

- **Open-core (the future lever):** MIT core for stars + a *separate closed-source*
  "Pathem Pro" superset (power features / sync / saved Layouts), ~$10–30. No
  license change, no fork/contributor problem on the paid part. Precedent in
  this exact category: Rectangle (MIT) + Rectangle Pro (closed), same solo dev.
- **Sell the identical binary:** notarized, auto-updating, support-backed build
  via Paddle/FastSpring (own the customer, ~95% kept), MIT permits selling
  copies. Optional paid **MAS convenience SKU** later (separate, sandbox-limited;
  must not compromise the non-sandboxed flagship).
- **GitHub Sponsors** + paid priority-support tiers from day one.
- **Do NOT** fee-based-dual-license MIT (earns nothing, MIT already permits
  commercial use; real dual-licensing needs a copyleft side = a license change =
  star cost).
- **Iron rules:** never relicense-to-restrictive later; never paywall a
  previously-free feature; the on-device semantic search stays **free** in the
  OSS build forever, only a *cloud* variant could ever be paid.
- **Dependency-license guardrail (load-bearing once remote protocols land):**
  every dependency bundled in a shipped build, free OR Pro, must be permissive
  (MIT / BSD / Apache-2.0 / curl). MIT lets you sell and close-source on top, but
  a single GPL/AGPL dependency or copied GPL snippet would make a closed Pro
  build non-distributable. Concretely: FTP/FTPS/SFTP via libcurl (curl license)
  and/or SwiftNIO + swift-nio-ssh (Apache-2.0); S3/WebDAV via URLSession; if
  torrents are ever pursued, libtorrent-rasterbar is BSD-3 (permissive). NEVER
  copy code from FileZilla, Cyberduck, Transmission, or qBittorrent (all GPL),
  reimplement from the protocol specs. This extends the day-one "no GPL in the
  MIT tree" rule to the whole shipped dependency graph.
- **A separate standalone, auto-updating build is already permitted** (two
  independent grounds, recorded so it is not re-litigated): you are the sole
  copyright holder, so you can license your own work under any terms for your own
  builds; and MIT itself grants the right to sell and distribute copies. So a
  notarized, Sparkle-auto-updating download (free or paid) and the open-core Pro
  are both fine with zero license change. Build-from-source is the current
  distribution choice, not a license limitation; both can coexist. The CLA is for
  relicensing the open core later, not a prerequisite for shipping closed Pro on
  MIT contributions (MIT already permits closed derivatives); it stays prudent
  but is not blocking.

### Launch strategy: two launches
- **Launch 1, native engine + minimal dual-pane.** "Show HN: a native macOS
  file manager that renders 1M rows." The speed is the product.
- **Launch 2, on-device semantic search**, months later. Two launches = two
  star spikes = two blog posts.
- **Build in public 3–6 weeks first** (demo clips on X/Bluesky, an r/swift
  virtualization thread) to manufacture the first-hour HN velocity that is the
  #1 ranking factor.
- **One Show HN shot:** Tue–Thu 8–10am PT; link the repo; hero GIF + working
  notarized DMG; own technical top-comment with honest limitations; reply within
  ~10 min for 2 hours. Stagger cross-posts (r/macapps, r/swift, r/MacOS,
  Lobsters). **Never solicit upvotes; no paywall/email gate on the download.**
- **After 225+ stars:** Homebrew cask + awesome-list PRs + AlternativeTo. Product
  Hunt a few days after HN.
- **README:** a <15s 1M-row scroll GIF above the fold; "Native AppKit. No
  Electron. 1M+ files instantly."; real benchmarks; CONTRIBUTING.md +
  good-first-issues + Sponsors.

### Career signal (the actual payoff)
The flagship blog post, "How I built a 1M-row native macOS file manager in
Swift/AppKit", is the highest-leverage artifact: it drives the launch *and* is
the 45-second recruiter narrative. Foreground systems depth (getattrlistbulk,
cell recycling, lazy outline, two-tier watcher), show sustained maintenance, put
Pathem atop the résumé with stars + benchmark. Optional conference/meetup talk.

### Reconciliation
- §1 "no subscription, privacy-forward" stays, a promise to users, orthogonal
  to the source license, and a strong anti-Path-Finder line.
- §8.3 direct-only non-sandboxed distribution stays for the **free flagship**;
  any paid MAS SKU is a separate, optional, sandbox-limited convenience build.
- The earlier "businesses pay $5/seat" idea is **killed** (source-available
  would cap stars and invite a fork, the opposite of the goal).

## 10. Customization and extensibility architecture (decided)

The Directory-Opus-class superuser layer (layouts, per-folder view formats,
custom columns, configurable toolbars and keybindings, themes, saved searches, a
command/FAYT palette) plus an extension story. Designed and fact-checked via a
research workflow.

### The spine: one command registry

Define a single Command vocabulary (id, title, help, typed args, handler) and
route every action (copy, move, paste, navigate, view changes, search) through
it. Then toolbars, keybindings, menus, the FAYT/command palette, the AI command
bar, and saved-search triggers are all thin declarative bindings to that
registry. Build this first: it is the cheapest high-leverage piece, and every
later feature becomes a thin data layer plus an automatic palette entry and a
bindable key.

### Customization is config-as-data (no third-party code)

Everything ships as schema-versioned Codable JSON under
~/Library/Application Support/Pathem/ (layouts, formats, columns, toolbars,
keymap, themes, searches, collections), pretty-printed with sorted keys so files
are hand-editable and shareable (the file itself is the shareable artifact, like
a Dir Opus .dcf). Forward-compatibility rules: additive-only fields, ignore
unknown keys on read and re-emit captured unknown keys on write (so an older
Pathem does not strip a newer user's fields), and an in-house migration registry
for breaking bumps. JSON, not TOML or YAML (stdlib-first: Foundation Codable, no
dependency).

Three subsystems reuse one tiny declarative mini-language (template tokens like
{name.stem} and {size:human}, globs, regex-extract, ranges, UTI, plus a semantic
query field over the existing embeddings), interpreted in-process over known
getattrlistbulk fields with no user code: custom columns; a per-folder, wildcard,
and content-type view-format cascade (exact path beats glob beats default, with
per-folder view changes auto-remembered); and saved-search predicates. Layouts
serialize the pane split and each pane's path, tabs, view format, and toolbar;
lighter Styles apply view and toolbar settings without moving. Themes are a
closed named-token map resolved through system colors, so dark mode and
increase-contrast come for free.

### Extensions: Swift only (decided), and out-of-process

Per the standing rule there is no embedded scripting language (no JavaScript, no
Lua, hence no JavaScriptCore). The native automation surface is App Intents and
Shortcuts (pure Swift, future-proof) over the same command registry, plus
NSServices. If code-backed extensions are ever needed, they are out-of-process
Swift helpers speaking line-delimited JSON over stdin/stdout (or a real XPC
service later), each signed with the app's Team ID and notarized, crash-isolated,
and inheriting none of the app's TCC grants. Never load in-process third-party
bundles: disable-library-validation is process-global and would hand any loaded
library the app's Full Disk Access. Never build in-process native viewer or VFS
plugins; cover viewing through QuickLook and built-ins. Design the contributes
manifest schema now (commands, columns, viewers, menu items, keybindings,
themes) so a future Swift extension can slot in without breaking the config
format, but do not build the runtime until real demand justifies the trust and
review burden.

Because there is no embedded engine and no in-process foreign code, Pathem keeps
a clean Hardened Runtime with no opt-outs (no allow-jit, no
disable-library-validation), which is a real security and notarization story
worth stating in the README. This is the chief benefit of the Swift-only rule:
it sidesteps JavaScriptCore's allow-jit requirement entirely (the original
research proposed JSC and the fact-check showed it needs that opt-out).

### AI command bar (on-device)

Each Command auto-becomes a Foundation Models tool (description from its title
and help, @Generable args mirroring its typed schema, @Guide to constrain
enum-like args). Pre-filter to the top-k candidate commands with the existing
NaturalLanguage embeddings before tool-calling (small on-device context). Gate on
SystemLanguageModel.availability and keep FAYT as the always-works baseline;
confirm before any model-chosen destructive action. The model only picks a
command id and fills typed args; it never runs free-form code.

### Phased roadmap

0. Command registry (foundation; route existing actions through it; add a command
   and script log panel).
1. Declarative customization over the registry: rebindable keymap, configurable
   toolbars, customizable context menu, themes.
2. Marquee Opus features as data: per-folder/wildcard/content-type view-format
   cascade, declarative custom columns, Layouts and Styles.
3. FAYT/command palette as one multi-mode widget: bare text filters, ">" is the
   command palette, "/" jumps to a path, "~" or "?" runs on-device semantic
   search. Saved searches and collections.
4. App Intents and Shortcuts (primary OS automation) plus NSServices. Finder Sync
   and AppleScript are optional later.
5. On-device natural-language command bar over the registry (Foundation Models).
6. Deferred by default: out-of-process Swift helper extensions for transfer/VFS
   backends and viewers, gated by real demand. No embedded scripting, ever.

### Status (built)

Phases 0 to 5 are implemented and on `main`, each behind the engine where the
logic is testable:

- 0: `CommandRegistry` (engine), browser actions dispatch by id.
- 1: `Keymap` (engine, config-as-data); keys resolve to commands, rebindable via
  `keymap.json`. Configurable toolbars/context-menu/themes from this phase are
  not done yet.
- 2: `ViewFormat` and `FolderFormats` (engine): sortable columns, hidden toggle,
  per-folder exact/subtree view cascade with apply-to-subfolders, and `Layouts`.
  Declarative custom columns and Styles are not done yet.
- 3: `FuzzyMatch` (engine) plus a `CommandPalette` (Cmd-Shift-P). The single
  multi-mode FAYT widget ("/", "~" modes) and saved searches are not done yet.
- 4: `SemanticSearchIntent` + `PathemShortcuts` (App Intents). These register
  only once Pathem ships as a real `.app` bundle; NSServices share that gate and
  are deferred to packaging.
- 5: `CommandResolver` (engine heuristic, always works) plus `FoundationModelMatcher`
  (on-device LLM on macOS 26 + Apple Intelligence) behind an async AI command bar
  (Cmd-Shift-A).

Two confirmed-bug adversarial-review passes (customization layer, then the
palette/AI glue) have been run against this code.

### Scope for the career goal

Phases 0 to 3 are the whole worthwhile investment and the "Directory Opus
successor" narrative: pure data over one registry, zero security or notarization
risk, demos well, bounded effort. Phase 4 (App Intents) and Phase 5 (on-device
NL bar) are the disproportionate ML and portfolio payoff. Phase 6 is where
over-investment lurks; design the manifest seam now, build the runtime later or
never.

---

*Provenance: research + architecture proposals + adversarial fact-check via
multiple multi-agent workflows; technical claims verified on macOS 26.5.1 /
arm64 / Swift 6.3.2. This is engineering analysis, not legal advice (license and
trademark notes are a preliminary screen, get a lawyer consult before launch).*
