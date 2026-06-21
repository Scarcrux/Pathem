# Design — a superuser file manager for macOS

> Name: **Pathom** (decided). Repo codename: `scarcrux-macfinder` (the
> `macfinder` working name is retired — it contains Apple's "Finder" mark).
> `pathom.app` is available (RDAP-confirmed); secure it + run USPTO TESS
> clearance (Classes 9 & 42) before branding spend.

Status: **design phase**. This document records the competitive analysis, the
language/architecture decision, and the MVP cut. It is the output of a
multi-agent research pass (5 research agents → 3 architecture proposals →
judge → adversarial critic) whose load-bearing technical claims were verified
on this machine (macOS 26.5.1, arm64, Swift 6.3.2).

---

## 1. Vision

A deeply **native**, **high-performance** macOS file manager — the spiritual
successor to Windows' **Directory Opus**, aimed past Cocoatech's **Path Finder**
and far past Finder. "Superuser" means the file view is a configurable
workspace, not a fixed window: dual-pane, tabs, saved layouts, per-folder
formats, find-as-you-type, batch rename, and (eventually) a command/scripting
system. Built by a solo dev, perpetual-license (no subscription), on-device,
privacy-forward.

Per CONVENTIONS.md: right-language-for-runtime, stdlib-first, **stay narrow**
(each feature earns its complexity), single notarized binary, no bundled
runtime.

---

## 2. Competitive analysis

### Directory Opus (Windows, GP Software) — the thing to live up to
Not a prettier Explorer; a programmable workspace. The features that make it
"superuser" and are worth cloning:

- **Lister + Layouts** — the core mental model. A *Lister* is a file window
  (single/dual pane, optional tree + viewer + metadata pane); a *Layout* is a
  saved snapshot of one or more Listers (tabs, panes, tree state, columns,
  toolbars) you reopen in one click. Define an environment per task, snap into
  it instantly. **This is the biggest leap over Finder.**
- **Dual/multi-pane + heavy tabbed browsing** (source-left/dest-right; dozens
  of persistent, lockable tabs).
- **Find-As-You-Type (FAYT)** — any keystroke opens a bottom field: Find /
  Filter (live wildcard narrow) / Command (`>`) / DOS (`?`), with an `=`
  expression evaluator (`=size>100kb`). Collapses navigation, filtering,
  ad-hoc commands, and metadata queries into one keyboard-driven field.
- **Flat View** — collapse a whole tree into one operable listing; sort /
  filter / rename / de-dup across all levels at once.
- **Per-folder / wildcard folder formats** — the view auto-reshapes to
  content (images → thumbnails + EXIF columns; music → tags + bitrate).
- **Advanced batch rename** — regex + macros + metadata-driven naming + live
  preview + saveable presets. A bulk-rename utility built in.
- **File Collections + saved searches + duplicate finder** — virtual folders
  you can act on across origins.
- **Command system + ActiveX scripting + button/command editor** — the true
  differentiator: nearly every behavior is a scriptable command.

There is **no macOS version and never has been** (Windows/AmigaOS only). v13
moved to an "upgrade subscription" (perpetual license, paid updates).

### Path Finder (Cocoatech) — correction to a stale assumption
**Important:** Path Finder is **not** discontinued and **not** subscription-
*only* anymore. As of mid-2026 it's actively developed (v26.x, date-based
numbering, Apple-Silicon native). Pricing now offers **three** paths: 30-day
trial, **a perpetual-style license key is back** (~$30), *and* a subscription
($2.95/mo or $29.95/yr); also on Setapp. So "it's subscription-based" is no
longer the whole story — but the subscription pivot is exactly what burned its
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
- **ForkLift 4** (Swift, ~80% SwiftUI, one-time $20–70) — the benchmark to
  beat. Best-in-class remote/transfer/sync. Actively developed, Tahoe-native
  (4.6.4, Jun 2026). **The MVP competes against ForkLift's maturity, not
  against Finder.**
- **QSpace / QSpace Pro** (native AppKit, up to 12 panes, one-time + paid
  extensions) — strong, but a-la-carte upsells raise trust questions.
- **Marta** (pure Swift, Lua-customizable, free) — beloved but ships
  erratically (pre-1.0, long gaps).
- **Nimble Commander** (C++ core, GPLv3, fast) — steep Norton-Commander UX.
- **Commander One** (dated), **TotalFinder** (dead, needs SIP off),
  **HoudahSpot** (search specialist, not a manager), **Tokie** (folders as
  Notion-style DBs, non-native), AI organizers (Sortio/Mane/Filex — search
  utilities, not managers).

**Genuine white-space (no single app combines these):**
1. Truly native + fast + modern (Liquid-Glass-era) UI, **and**
2. AI-native **on-device semantic / natural-language search**, **and**
3. Rich **metadata/tags as a first-class sortable column-database**, **and**
4. Great transfer/sync — **with a perpetual, no-subscription license.**

Each competitor wins one axis and loses the others. That's the opening.

### Lead differentiator: integrated LLM support (decided)

Per the market analysis above, the #1 white-space is AI: no native, fast Mac
file manager has integrated LLM support. This is Pathom's chosen north-star
differentiator. Candidate capabilities (sequenced *after* the engine is stable):

- **Semantic / natural-language search** — "the contract I edited last spring,"
  "screenshots with errors" — over an on-device content index.
- **Natural-language file ops** — describe a batch rename / move / filter and
  preview the resulting operations before applying (always undoable).
- **Content-aware organize & rename** — suggest names/folders from file
  contents; semantic dedup.
- **Ask-about-this** — summarize, extract from, or compare selected files.

Constraints to settle in a dedicated LLM design phase (not now):

- **Privacy-forward.** Prefer on-device where viable; for any cloud call,
  explicit scoped consent — never silently upload file contents. This is itself
  a trust differentiator vs. the AI-organizer crowd.
- **Provider.** Default to the latest Claude models (Opus 4.8 / Sonnet 4.6 /
  Haiku 4.5) for cloud; evaluate on-device models for privacy/cost. Use the
  `claude-api` skill when we design/build this.
- **Cost & latency.** Index incrementally, cache, and keep LLM calls off the
  hot path. Gate the whole feature behind the stable core (stay narrow).

#### LLM engine strategy (decided after research)

"Bundle a local LLM?" → **partly — decouple search from generation.**

- **Search = embeddings, not an LLM.** A tiny embedding model (Apple
  `NLContextualEmbedding`, 0 bundle bytes / ~100MB on-demand asset; or a bundled
  `bge-small`, MIT, ~30-65MB) + a local vector index (`sqlite-vec`, 384-dim,
  int8/binary). Runs on ~100% of Macs incl. Intel. **This is the AI MVP** and
  the broad-reach headline; it never hallucinates a file reference.
- **Generation = Apple Foundation Models (primary, 0 bundle bytes).** macOS 26's
  built-in ~3B on-device model. `@Generable` constrained decoding yields a
  *typed* FileOperationPlan we preview + user confirms + OUR code executes — the
  LLM never touches the filesystem (safe for destructive ops). Sweet spot =
  summarize / extract / classify = features 2/3/4.
- **Fallback (optional, downloaded on first run — NEVER in the .app):** a small
  Apache-2.0 LLM via `mlx-swift` (Qwen3-4B ~2.5GB, or 1.7B for low-RAM) for
  Apple-Intelligence-ineligible Macs (Intel / AI-off). RAM-gated.
- **Cloud (optional, consented):** Claude (Opus 4.8 / Sonnet 4.6; Haiku 4.5 for
  cheap classification) for large-corpus compare/summarize beyond the on-device
  ~4K context. Per-action consent; send only the selected file/region. Build
  with the `claude-api` skill. (Note for build time: Claude 4.6+ uses adaptive
  thinking, not `budget_tokens`; use `output_config.format` + strict tools;
  Haiku 4.5 is 200K context.)
- **License rule:** bundle only OSI-permissive weights (Apache-2.0 / MIT: Qwen3,
  SmolLM2, Phi-4-mini, bge-small, Model2Vec). **Avoid Llama (Community License)
  and Gemma (custom terms)** — open-weight, not OSI, with UI/redistribution
  strings.
- **AI is progressive enhancement.** Core file manager works without it
  (glob/regex batch ops, metadata search, manual templates).
- **Caveats:** Foundation Models needs Apple silicon + macOS 26 + Apple
  Intelligence enabled (Intel excluded; Tahoe adoption ~52% near-term);
  **~4K on-device context** (macOS 26.4 — retrieve-then-feed only the relevant
  passages, pre-flight every prompt with `tokenCount()`, handle
  `.contextWindowExceeded`; don't stuff whole files).

> Fact-checked (2026): architecture verified sound. Licenses, model sizes,
> hardware gating, and Claude model IDs all confirmed. Corrections applied:
> on-device context is ~4K (not 8K). Additional notes: at true
> millions-of-files scale use binary/int8 vectors or USearch (HNSW) — sqlite-vec
> brute-force suits ~100k-500k chunks; don't pin the fallback to one model, pick
> the latest Apache-2.0 ~3-4B at build time; read embedding dimensionality from
> the API at runtime and store the model id+revision with the index (any swap
> forces a full re-index).

---

## 3. Language & architecture decision

### Decision: **Swift** — one language, one toolchain, one debugger.
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
  C shim — **exactly as Rust would.**

### The non-negotiable: the file list is **view-based `NSTableView` /
`NSOutlineView`**, not SwiftUI.
Verified: SwiftUI `List`/`Table` does **not** virtualize on macOS and collapses
well below target (~900ms per selection change at ~1000 rows; auto-diff can't
be disabled). AppKit view-based tables with genuine cell recycling are the
documented ceiling for 100k+ rows at 120fps. The file list **is** the product,
so it gets the proven control.

### Alternatives, and why rejected
- **Pure SwiftUI file view** — fatal: no virtualization at scale. (SwiftUI is
  fine for chrome only.)
- **Rust core + Swift UI** — scored 33. FFI is mechanically sound (verified: a
  Rust staticlib linked into SwiftPM returned a value across the C ABI), but
  Swift hits the *same* `getattrlistbulk` syscall through the *same* shim, so
  Rust buys **~0 MVP performance** while imposing a permanent two-toolchain
  tax. Rust's real wins (jwalk/rayon recursion, Tantivy index) are all
  deferred. Per stdlib-first + "documented trigger," it's the **deferred
  escape hatch**, not the start. (A real fragility was reproduced live: the
  cargo cache built into a *sibling project's* path-derived bucket
  `~/Library/Caches/cargo-targets/hearthsim/`.)
- **Rust + GPUI/egui**, **Tauri**, **Electron/Qt/Flutter** — all forfeit native
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
1. **Enumerator** — `getattrlistbulk`, 128KB buffer, requests *only displayed
   attributes*, emits fixed-layout `FileEntry` value-type structs into a
   contiguous array (no `NSURL` in the loop).
2. **DirectoryModel** — owns the per-pane snapshot; sorts/filters in place into
   an index vector.
3. **Watcher (two-tier)** — always-on **FSEvents** (FileEvents flag, persisted
   event ID for replay) for the tree, plus **DispatchSource/kqueue** on
   *currently-visible* dirs only; mandatory `MustScanSubDirs`/Dropped subtree
   re-scan (with its **own** debounce/coalescing — a build/unzip can thrash).
4. **OpService** — off-main bulk ops; `copyfile COPYFILE_CLONE` same-volume;
   direct POSIX xattr access; **app-owned `NSUndoManager`** undo stack.
5. **SearchService (dual-path)** — `MDQuery` for instant indexed results **plus**
   a raw walker as Spotlight-independent ground truth. (Benchmark `fts_open`/
   `fts_read` vs `getattrlistbulk` for the *recursive* path before committing —
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
  field + migration path from v1) — the DOpus "customize everything" ethos,
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
   on one `getattrlistbulk`. (Target sub-100ms *interactive* — note: a windowed
   AppKit app will **not** hit the constellation's CLI-class sub-10ms; that
   target doesn't apply here.)
6. Thumbnails: instant `NSWorkspace` type icons first → `QLThumbnailGenerator`
   for visible+overscan only, cancel-on-scroll, bounded `NSCache` LRU keyed by
   URL+mtime+size, progressive quality; **never block scroll**; budget for the
   QuickLook daemon stalling on malformed files (when-not-if on a whole-disk
   browser).
7. Same-volume copy via `COPYFILE_CLONE`; xattrs/tags via direct POSIX.

**Proof gates (before any chrome):**
- **Gate A** — scroll a **synthetic 1M-entry directory** smoothly (validates
  virtualization).
- **Gate B** — expand a synthetic node with **100k+ direct children** with no
  main-thread stall (the lazy `ProxyItem` outline data source is the single
  riskiest piece of AppKit in the app; it gets its own milestone).

---

## 6. MVP cut (stay narrow)

1. Single-window file view on the `getattrlistbulk` enumerator + view-based
   `NSTableView` — **pass Gates A & B first** (make-or-break).
2. Core navigation: `NSPathControl` **editable address bar**, descend/back/
   forward/parent, native keyboard nav + type-select.
3. Two-tier watcher with `MustScanSubDirs`/Dropped re-scan (correctness gate,
   not optional).
4. Sortable columns (name, size, kind, dates) on the struct array; instant
   hidden-files toggle.
5. Off-main file ops w/ progress: copy (clone same-volume), move, rename, new
   folder, **New File**, delete-to-Trash + **app-owned undo** — gated behind a
   **conflict-resolution policy** (overwrite / keep-both / skip / apply-to-all;
   cross-volume move = copy→verify→delete, never delete on partial failure;
   interruption recovery).
6. Async thumbnails done right + spacebar `QLPreviewPanel`.
7. A single keyboard-driven **FAYT** field that live-filters the in-memory
   struct array (no Spotlight dependency — nearly free given the engine holds
   the snapshot).
8. **Dual-pane (minimal)** — ✅ **in MVP.** Two side-by-side file views
   (source/destination) with one-key copy/move between them; it's category
   table-stakes (every competitor ships it). Full multi-pane, tabs, and saved
   Lister/Layout workspaces stay deferred.
9. Non-sandboxed notarized bundle + first-run Full Disk Access prompt.
10. **App update mechanism** — wire **Sparkle** (EdDSA appcast) now; generate/
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
    reporter) — whole-disk access + unsafe-pointer syscall parsing + no CI +
    bus-factor-of-one.

**Explicitly deferred** (each must earn past "stay narrow" on a stable
engine): tabs, Lister/Layout workspaces (then add as Codable JSON), flat view,
FAYT `=` evaluator, scripting/command system, batch-rename engine (high-
goodwill — add early as a showcase), collections/saved searches, archive-as-
folder, FTP/SFTP, inspector/modules, labels/ratings, **integrated LLM support**
(the lead differentiator; see §2 — gate behind a stable core), and **any
Rust subsystem** (Tantivy index / jwalk) — gated behind a measured profiling
trigger + a contract/probe test on the new ABI boundary (pin struct layout,
fail loudly on drift; pin `CARGO_TARGET_DIR` per-project).

> Honest framing: the MVP-as-cut is a *faster, more native Finder* — an engine
> proof. It is **not yet** a reason to leave ForkLift. The differentiators
> (dual-pane workspaces, semantic search, metadata-DB columns, no-subscription
> positioning) are what make it a competitor; sequence them deliberately.

---

## 7. Naming

`macfinder` is out (contains Apple's "Finder" mark; also Apple disallows "Mac"
in third-party product names — so "Mac Explorer" is out, and "Power Explorer"
sits in Microsoft's "Power*"/"Explorer" family and is generically weak).

**Decision: Pathom** (preliminary screen, **not** legal clearance):

| Name | Why | TM risk | Notes |
|------|-----|---------|-------|
| **Pathom** ✅ chosen | coined from "path"; reads as navigation | **LOW** | no software/app collision found; coined → easiest to own *and defend*. `pathom.app` **available** (RDAP 404 confirmed); `pathom.com` likely held by an unrelated consultancy → use `getpathom.com`. `.app` is HTTPS-only (free TLS). |
| **Bursar** | "keeper of the stores/keys" → custody + control | LOW | cleanest real-word lane found in a 2nd naming round (no software collisions). Recorded only as a fallback if Pathom is ever revisited. |

Two naming rounds ran (coined words, then recognizable real words). The
tradeoff accepted: a coined word is the most ownable/defensible class of mark
but carries no built-in meaning, so brand/positioning must teach it ("Pathom —
a file manager for Mac"). No real word cleared the file-manager lane as cleanly
as Pathom without either a collision or weaker defensibility, so Pathom stands.

Before branding spend: secure `pathom.app` (+ `getpathom.com`) and run a full
USPTO TESS knockout search in Classes 9 & 42.

---

## 8. Open decisions

1. ~~**Name**~~ — **Decided: Pathom.**
2. ~~**Dual-pane in MVP?**~~ — **Decided: yes (minimal — two panes, one-key
   copy/move). Multi-pane/tabs/Layouts deferred.**
3. ~~**Update channel / Mac App Store?**~~ — **Decided: direct-only,
   non-sandboxed (user-granted Full Disk Access), updates via Sparkle (EdDSA
   appcast, key generated at v0). MAS is skipped — the App Sandbox cannot
   grant Full Disk Access, which would gut the whole-filesystem "superuser"
   reach the product exists for.**
4. **First differentiator after the engine** — north-star is **integrated LLM
   support** (§2). Open question is the *first shippable slice*: a small LLM win
   (e.g. natural-language filter / rename preview) vs. a non-LLM showcase (saved
   Layouts or the batch-rename engine) to ship while the content index matures.

---

*Provenance: research + architecture proposals + adversarial fact-check via a
10-agent workflow; technical claims verified on macOS 26.5.1 / arm64 /
Swift 6.3.2. This is engineering analysis, not legal advice (trademark notes
are a preliminary screen).*
