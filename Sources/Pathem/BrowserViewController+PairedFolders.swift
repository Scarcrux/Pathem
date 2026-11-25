import AppKit
import PathemEngine

// Paired folders: a left folder and the right folder it corresponds to. With "Follow Paired
// Folder" on, moving into a subfolder or up in one pane takes the other pane to the same relative
// path inside its half of the pair.
@MainActor
extension BrowserViewController {
    func registerPairedFolderCommands() {
        func add(
            _ id: String, _ title: String, keywords: [String] = [],
            enabled: @escaping () -> Bool = { true }, _ run: @escaping () -> Void
        ) {
            commands.register(
                .init(id: id, title: title, keywords: keywords, isEnabled: enabled, run: run))
        }
        add(
            "pairs.follow", L("bvc.cmd.followPairedFolder", "Follow Paired Folder"),
            keywords: ["paired folders", "mirror", "link panes"]
        ) { [weak self] in self?.toggleFollowPairedFolders() }
        add(
            "pairs.pairThese", L("bvc.cmd.pairTheseFolders", "Pair These Folders"),
            keywords: ["paired folders", "link folders"],
            enabled: { [weak self] in self?.localPaneFolders() != nil }
        ) { [weak self] in self?.pairTheseFolders() }
        add(
            "nav.sameFolderOtherPane",
            L("bvc.cmd.sameFolderOtherPane", "Go to Same Folder in Other Pane"),
            keywords: ["match folder", "mirror folder", "paired folders"],
            enabled: { [weak self] in self?.localPaneFolders() != nil }
        ) { [weak self] in self?.goToSameFolderInOtherPane() }
    }

    /// Both panes' folders when each shows a local folder (not remote, not a smart listing).
    func localPaneFolders() -> (left: URL, right: URL)? {
        guard let left = leftTabs.activePane, let right = rightTabs.activePane,
            !left.isRemote, !right.isRemote, !left.isShowingSmartResults,
            !right.isShowingSmartResults
        else { return nil }
        return (left.rootURL, right.rootURL)
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private var activePairSide: PairSide { activeSide === leftTabs ? .left : .right }

    func toggleFollowPairedFolders() {
        followPairedFolders.toggle()
        pairedLastFolder = [:]
        if followPairedFolders {
            for side in [leftTabs, rightTabs] {
                if let pane = side.activePane, !pane.isRemote {
                    pairedLastFolder[ObjectIdentifier(pane)] = pane.rootURL.standardizedFileURL.path
                }
            }
        }
        refreshPairIndicators(noMatch: false)
        activePane?.flashStatus(
            followPairedFolders
                ? L("pairs.followOn", "Following paired folders")
                : L("pairs.followOff", "Paired folders no longer followed"))
    }

    /// Record the current two folders as a pair, in Settings > Layout > Paired Folders.
    func pairTheseFolders() {
        guard let folders = localPaneFolders() else {
            NSSound.beep()
            return
        }
        let before = prefs.pairedFolders.count
        prefs.pairedFolders = PairedFolders.adding(
            FolderPair(left: folders.left.path, right: folders.right.path),
            to: prefs.pairedFolders)
        saveConfig(prefs, to: Self.preferencesURL)
        activePane?.flashStatus(
            prefs.pairedFolders.count == before
                ? L("pairs.alreadyPaired", "These folders are already paired")
                : L("pairs.paired", "Paired these folders"))
    }

    /// One-shot jump: take the other pane to the folder that matches this pane's folder, using
    /// the deepest pair that holds it, else the same-named folder in the other pane's parent.
    func goToSameFolderInOtherPane() {
        guard let folders = localPaneFolders(), let otherPane = otherPane else {
            NSSound.beep()
            return
        }
        let side = activePairSide
        let target = PairedFolders.sameFolder(
            pairs: prefs.pairedFolders, active: side,
            activeFolder: side == .left ? folders.left : folders.right,
            otherFolder: side == .left ? folders.right : folders.left, exists: Self.isFolder)
        guard let target else {
            activePane?.flashStatus(L("pairs.noMatch", "No matching folder in the other pane"))
            return
        }
        isSyncingPanes = true
        otherPane.navigate(to: target)
        isSyncingPanes = false
    }

    /// Called after the active pane lands in a folder: when following, take the other pane to
    /// the matching folder inside the pair, or show that there is none.
    func followPairedFolderIfNeeded(pane: PaneController, url: URL) {
        let key = ObjectIdentifier(pane)
        let here = url.standardizedFileURL.path
        let moved = pairedLastFolder[key] != here
        pairedLastFolder[key] = here
        guard followPairedFolders, moved, !isSyncingPanes, !pane.isRemote,
            !pane.isShowingSmartResults, let folders = localPaneFolders(),
            let otherPane = otherPane, !otherPane.isRemote
        else { return }
        let side = activePairSide
        let result = PairedFolders.counterpart(
            pairs: prefs.pairedFolders, moved: side, newFolder: url,
            otherFolder: side == .left ? folders.right : folders.left, exists: Self.isFolder)
        switch result {
        case .notApplicable:
            refreshPairIndicators(noMatch: false)
        case .noMatch:
            refreshPairIndicators(noMatch: true)
        case .follow(let target):
            refreshPairIndicators(noMatch: false)
            guard target.standardizedFileURL.path != otherPane.rootURL.standardizedFileURL.path
            else { return }
            isSyncingPanes = true
            pairedLastFolder[ObjectIdentifier(otherPane)] = target.standardizedFileURL.path
            otherPane.navigate(to: target)
            isSyncingPanes = false
        }
    }

    /// Show or hide the link marker on both panes' status rows.
    func refreshPairIndicators(noMatch: Bool) {
        for side in [leftTabs, rightTabs] {
            for pane in side.tabs {
                pane.setPairIndicator(
                    !followPairedFolders ? .hidden : (noMatch ? .noMatch : .following))
            }
        }
    }
}
