# Finder parity: shipped surfaces and remaining boundaries

This is an inventory, not a claim that every Finder feature has end-to-end coverage.
The pre-release batch adds bounded slices; the broad roadmap task stays pending.

| Feature | Pathem surface / evidence | Remaining boundary |
| --- | --- | --- |
| Compress ZIP / 7-Zip, alias/original, package contents, Quick Look | Shared context menu in five actual views; disposable operations and async selection races in `PATHEM_FINDER_UI_TEST` | Native appearance/physical menu tracking |
| Color tags, named labels | File > Label already used `LabelSet.default`; context menu previously had colors only. Batch reuses named labels, mixed/all-selected checkmarks and existing Finder-compatible xattr writes | Arbitrary tag-name editing, configured label-set editor, native-speaker review |
| Unsupported tag selection | Handlers reject remote and cross-folder smart selections; batch makes command/menu enablement agree | Live remote-provider acceptance, not inferred from fixture capability checks |
| Background view actions | Blank-selection View/Arrange By submenus reuse existing commands; 263 real-window validation/dispatch/layout checks cover all five views and 25 delivered view transitions. List/Icons render grouping; other views refuse unsupported grouping | Native popup enablement/physical tracking; grouping is not implemented in Gallery/Columns/Tree |
| Context-menu customization | Hiding/ordering dispatch through real content witnesses in five views; duplicate/obsolete entries filtered, new defaults appended. New-tab inheritance checked in the 132-check configuration matrix | Native popup tracking/appearance |
| Content preferences | Previously ignored color/format/middle-click hooks now dispatch; all five views render matching filename rules, including Gallery filmstrip color/font traits. List formats and real middle-button folder tabs work; new tabs inherit font/density, formats, menu and click settings. Styling preserves selection/viewport across five modes, expanded Tree and drilled Column. Initial configured tabs honor the saved global view; later navigation stays sticky and explicit folder views win. Settings/menu default-view and sort fields agree, with 588 mounted-control checks across 50 combinations and three startup-store variants | Column font/density support remains unsupported; other Settings controls, physical input, native baselines and broader legacy-config acceptance |
| Services / Quick Actions | App exports Open/Preview/Reveal in Pathem Services; Shortcuts picker exists | Generic context Services consumption and installed Quick Actions are not integrated/tested |
| Cloud Download | `files.download` calls `startDownloadingUbiquitousItem` for dataless selection; hermetic cloud seams have separate coverage | Live provider download; keep-downloaded/remove-download actions are not implemented |
| Eject | Sidebar uses a capability policy with positive/negative smoke controls; active-folder command checks volume path; handler has boot/system hard backstop | Unify command capability policy with sidebar; disposable virtual-volume UI routing; no real storage ejected by this batch |
| Open With / Always Open With | Choose selection now dispatches immediately to a native application picker nested on the opener alert. 35 mounted-control checks cover cancel/retry, empty candidate state, and scratch file/folder/session saves | Physical menu/picker acceptance and system-wide LaunchServices writes are not exercised; custom URL completion state is injected |
| Share | Native sharing picker exists, including system-dependent destinations | Live Messages/share-extension acceptance remains environmental |

Sources of truth: `FileContextMenu.swift`, `BrowserViewController+CommandRegistry.swift`,
`BrowserViewController+MenuValidation.swift`, `PaneController.swift`,
`BrowserViewController+RevealAndInspect.swift`, `SidebarController.swift`,
`BrowserViewController+SelectionTransforms.swift`, and `PathemApp.swift`.

Acceptance for the named-label slice: menu presence in all five actual views, delivered
mixed two-item selection, real tag writes to both disposable items, toggle removal,
empty/smart disabled controls and hiding Tags also hiding its named labels. Initial
baseline fails all five menu-presence checks and the smart-result capability check.
