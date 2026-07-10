import AppKit
import PathemEngine

// Workspaces: named view Styles, saved dual-pane Workspaces, and the
// Automation Rules panel/watcher lifecycle. Split out of BrowserViewController.
@MainActor
extension BrowserViewController {
    /// Save the active pane's current view format (mode, sort, hidden, folders-first) as a
    /// named Style.
    func saveStyle() {
        guard let pane = activePane else { NSSound.beep(); return }
        Task { @MainActor in
            guard
                let name = await self.promptForName(title: L("bvc.saveStyleTitle", "Save style as:"), default: ""),
                !name.trimmingCharacters(in: .whitespaces).isEmpty
            else { return }
            self.windowState.saveStyle(WindowStateStore.Style(name: name, format: pane.format))
        }
    }

    /// Pick a saved Style and apply it to the active pane.
    func applyStyle() {
        let all = windowState.styles()
        guard let window = view.window else { return }
        guard !all.isEmpty else {
            presentInfo(
                L("bvc.noStyles", "No styles"), L("bvc.noStylesBody", "Save one first with Save Style."))
            return
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 25))
        for style in all { popup.addItem(withTitle: style.name) }
        let alert = NSAlert()
        alert.messageText = L("bvc.applyStyleTitle", "Apply Style")
        alert.accessoryView = popup
        alert.addButton(withTitle: L("bvc.apply", "Apply"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                all.indices.contains(popup.indexOfSelectedItem)
            else { return }
            self.activePane?.applyFormat(all[popup.indexOfSelectedItem].format)
        }
    }

    /// Start the automation folder watchers (off in demo mode and under the smoke harness).
    func setupAutomation() {
        guard demoLayout == nil, ProcessInfo.processInfo.environment["PATHEM_SMOKE"] == nil else { return }
        _ = automation  // lazy init loads the rules and starts the watchers
    }

    func showAutomationRules() {
        automationRules.present(manager: automation, over: view.window)
    }

    /// Capture the current dual-pane, multi-tab layout under a name.
    func saveWorkspace() {
        Task { @MainActor in
            guard
                let name = await self.promptForName(title: L("bvc.saveWorkspaceTitle", "Save workspace as:"), default: ""),
                !name.trimmingCharacters(in: .whitespaces).isEmpty
            else { return }
            self.windowState.saveWorkspace(
                WindowStateStore.Workspace(
                    name: name, left: self.leftTabs.tabFolders, leftActive: self.leftTabs.activeTabIndex,
                    right: self.rightTabs.tabFolders, rightActive: self.rightTabs.activeTabIndex))
        }
    }

    /// Pick a saved workspace and switch both panes to its layout.
    func openWorkspace() {
        let all = windowState.workspaces()
        guard let window = view.window else { return }
        guard !all.isEmpty else {
            presentInfo(
                L("bvc.noWorkspaces", "No workspaces"),
                L("bvc.noWorkspacesBody", "Save one first with Save Workspace."))
            return
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 25))
        for workspace in all { popup.addItem(withTitle: workspace.name) }
        let alert = NSAlert()
        alert.messageText = L("bvc.openWorkspaceTitle", "Open Workspace")
        alert.accessoryView = popup
        alert.addButton(withTitle: L("common.open", "Open"))
        alert.addButton(withTitle: L("common.cancel", "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                all.indices.contains(popup.indexOfSelectedItem)
            else { return }
            let workspace = all[popup.indexOfSelectedItem]
            self.leftTabs.restoreTabs(workspace.left, active: workspace.leftActive)
            self.rightTabs.restoreTabs(workspace.right, active: workspace.rightActive)
            if let pane = self.leftTabs.activePane { self.setActiveSide(self.leftTabs, pane: pane) }
        }
    }
}
