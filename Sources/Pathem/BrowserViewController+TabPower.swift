import AppKit
import PathemEngine

// Tab power: lock, reopen closed, the most-recently-used switcher, and tab groups.
@MainActor
extension BrowserViewController {
    func registerTabPowerCommands() {
        func add(
            _ id: String, _ title: String, keywords: [String] = [],
            enabled: @escaping () -> Bool = { true }, _ run: @escaping () -> Void
        ) {
            commands.register(
                .init(id: id, title: title, keywords: keywords, isEnabled: enabled, run: run))
        }
        add(
            "tab.lock", L("tabs.lockTab", "Lock Tab"), keywords: ["pin", "pin tab"],
            enabled: { [weak self] in self?.activeSide?.activeTabIsLocked == false }
        ) { [weak self] in
            guard let side = self?.activeSide else { return }
            side.setLocked(true, at: side.activeTabIndex)
        }
        add(
            "tab.unlock", L("tabs.unlockTab", "Unlock Tab"), keywords: ["unpin", "unpin tab"],
            enabled: { [weak self] in self?.activeSide?.activeTabIsLocked == true }
        ) { [weak self] in
            guard let side = self?.activeSide else { return }
            side.setLocked(false, at: side.activeTabIndex)
        }
        add(
            "tab.reopen", L("bvc.cmd.reopenClosedTab", "Reopen Closed Tab"),
            keywords: ["undo close tab", "restore tab"],
            enabled: { [weak self] in self?.activeSide?.canReopenClosedTab == true }
        ) { [weak self] in
            if self?.activeSide?.reopenClosedTab() != true { NSSound.beep() }
        }
        add(
            "tab.switch", L("bvc.cmd.switchTabs", "Switch Tabs"),
            keywords: ["tab switcher", "recent tabs", "ctrl tab"],
            enabled: { [weak self] in self?.allTabEntries().count ?? 0 > 1 }
        ) { [weak self] in self?.openTabSwitcher(reverse: false) }
        add(
            "tab.switchReverse", L("bvc.cmd.switchTabsReverse", "Switch Tabs (Reverse)"),
            keywords: ["tab switcher"],
            enabled: { [weak self] in self?.allTabEntries().count ?? 0 > 1 }
        ) { [weak self] in self?.openTabSwitcher(reverse: true) }
        add(
            "tab.saveGroup", L("bvc.cmd.saveTabGroup", "Save Tabs as Group…"),
            keywords: ["tab group"]
        ) {
            [weak self] in self?.saveTabGroupPrompt()
        }
        tabSwitcher.onCommit = { [weak self] id in self?.activateTab(withIdentity: id) }
        registerPairedFolderCommands()
    }

    // MARK: - Switcher

    /// Every tab of both panes, most recently used first.
    func allTabEntries() -> [TabSwitcherEntry] {
        var byID: [ObjectIdentifier: TabSwitcherEntry] = [:]
        var live: [ObjectIdentifier] = []
        for (label, side) in [("L", leftTabs), ("R", rightTabs)] {
            for pane in side.tabs {
                let id = ObjectIdentifier(pane)
                live.append(id)
                byID[id] = TabSwitcherEntry(
                    id: id, sideLabel: label,
                    title: pane.smartListingTitle
                        ?? TabbedPaneController.title(for: pane.currentURL),
                    path: pane.currentURL.path, locked: pane.isTabLocked)
            }
        }
        var order = tabOrder
        order.sync(live: live)
        return order.order.compactMap { byID[$0] }
    }

    func openTabSwitcher(reverse: Bool, immediately: Bool = false) {
        tabSwitcher.open(
            entries: allTabEntries(), reverse: reverse, over: view.window, immediately: immediately)
    }

    private func activateTab(withIdentity id: ObjectIdentifier) {
        for side in [leftTabs, rightTabs] {
            if let index = side.tabs.firstIndex(where: { ObjectIdentifier($0) == id }) {
                side.selectTab(index)
                if let pane = side.activePane { setActiveSide(side, pane: pane) }
                return
            }
        }
    }

    // MARK: - Tab groups

    func saveTabGroupPrompt() {
        Task { @MainActor in
            guard
                let name = await self.promptForName(
                    title: L("tabs.group.saveTitle", "Save tabs as group:"), default: "")
            else { return }
            var store = self.windowState.tabGroups()
            store.save(
                TabGroup(
                    name: name, left: self.leftTabs.tabSnapshots,
                    leftActive: self.leftTabs.activeTabIndex, right: self.rightTabs.tabSnapshots,
                    rightActive: self.rightTabs.activeTabIndex))
            self.windowState.saveTabGroups(store)
        }
    }

    /// The File > Tab Groups submenu, rebuilt each time it opens.
    func populateTabGroupsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let save = menu.addItem(
            withTitle: L("bvc.cmd.saveTabGroup", "Save Tabs as Group…"),
            action: #selector(saveTabGroupMenu), keyEquivalent: "")
        save.target = self
        let groups = windowState.tabGroups().groups
        guard !groups.isEmpty else { return }
        menu.addItem(.separator())
        for group in groups {
            let item = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: group.name)
            func add(_ title: String, _ action: Selector) {
                let entry = sub.addItem(withTitle: title, action: action, keyEquivalent: "")
                entry.target = self
                entry.representedObject = group.name
            }
            add(
                L("tabs.group.replace", "Open, Replacing Current Tabs"),
                #selector(openTabGroupReplacing(_:)))
            add(
                L("tabs.group.add", "Open, Adding to Current Tabs"),
                #selector(openTabGroupAdding(_:)))
            sub.addItem(.separator())
            add(L("tabs.group.rename", "Rename…"), #selector(renameTabGroupMenu(_:)))
            add(L("tabs.group.delete", "Delete"), #selector(deleteTabGroupMenu(_:)))
            item.submenu = sub
            menu.addItem(item)
        }
    }

    @objc private func saveTabGroupMenu() { saveTabGroupPrompt() }
    @objc private func openTabGroupReplacing(_ sender: NSMenuItem) {
        openTabGroup(sender, replacing: true)
    }
    @objc private func openTabGroupAdding(_ sender: NSMenuItem) {
        openTabGroup(sender, replacing: false)
    }

    private func openTabGroup(_ sender: NSMenuItem, replacing: Bool) {
        guard let name = sender.representedObject as? String,
            let group = windowState.tabGroups().group(named: name)
        else { return }
        leftTabs.openGroupTabs(group.left, active: group.leftActive, replacing: replacing)
        rightTabs.openGroupTabs(group.right, active: group.rightActive, replacing: replacing)
        if let pane = leftTabs.activePane { setActiveSide(leftTabs, pane: pane) }
    }

    @objc private func renameTabGroupMenu(_ sender: NSMenuItem) {
        guard let old = sender.representedObject as? String else { return }
        Task { @MainActor in
            guard
                let new = await self.promptForName(
                    title: L("tabs.group.renameTitle", "Rename tab group:"), default: old)
            else { return }
            var store = self.windowState.tabGroups()
            if store.rename(old, to: new) {
                self.windowState.saveTabGroups(store)
            } else {
                NSSound.beep()  // empty, or another group already has that name
            }
        }
    }

    @objc private func deleteTabGroupMenu(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var store = windowState.tabGroups()
        store.delete(named: name)
        windowState.saveTabGroups(store)
    }
}
