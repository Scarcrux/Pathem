# Finder parity: shipped surfaces and remaining boundaries

This is an inventory, not a claim that every Finder feature has end-to-end coverage.
The pre-release batch adds bounded slices; the broad roadmap task stays pending.

| Feature | Pathem surface / evidence | Remaining boundary |
| --- | --- | --- |
| Compress ZIP / 7-Zip, alias/original, package contents, Quick Look | Shared context menu in five actual views; disposable operations and async selection races in `PATHEM_FINDER_UI_TEST` | Native appearance/physical menu tracking |
| Color tags, named labels | File > Label already used `LabelSet.default`; context menu previously had colors only. Batch reuses named labels, mixed/all-selected checkmarks and existing Finder-compatible xattr writes | Arbitrary tag-name editing, configured label-set editor, native-speaker review |
| Unsupported tag selection | Handlers reject remote and cross-folder smart selections; batch makes command/menu enablement agree | Live remote-provider acceptance, not inferred from fixture capability checks |
| Background view actions | View menu and toolbar expose five modes; blank-selection context has file-creation actions but no Finder-style view/arrange submenu | Background menu parity is still missing |
| Services / Quick Actions | App exports Open/Preview/Reveal in Pathem Services; Shortcuts picker exists | Generic context Services consumption and installed Quick Actions are not integrated/tested |
| Cloud Download | `files.download` calls `startDownloadingUbiquitousItem` for dataless selection; hermetic cloud seams have separate coverage | Live provider download; keep-downloaded/remove-download actions are not implemented |
| Eject | Sidebar uses a capability policy with positive/negative smoke controls; active-folder command checks volume path; handler has boot/system hard backstop | Unify command capability policy with sidebar; disposable virtual-volume UI routing; no real storage ejected by this batch |
| Share | Native sharing picker exists, including system-dependent destinations | Live Messages/share-extension acceptance remains environmental |

Sources of truth: `FileContextMenu.swift`, `BrowserViewController+CommandRegistry.swift`,
`BrowserViewController+MenuValidation.swift`, `PaneController.swift`,
`BrowserViewController+RevealAndInspect.swift`, `SidebarController.swift`,
`BrowserViewController+SelectionTransforms.swift`, and `PathemApp.swift`.

Acceptance for the named-label slice: menu presence in all five actual views, delivered
mixed two-item selection, real tag writes to both disposable items, toggle removal,
empty/smart disabled controls and hiding Tags also hiding its named labels. Initial
baseline fails all five menu-presence checks and the smart-result capability check.
