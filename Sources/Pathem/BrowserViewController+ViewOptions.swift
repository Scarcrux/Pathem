import AppKit
import PathemEngine

extension BrowserViewController {
    func showViewOptions() {
        guard let pane = activePane, !pane.isRemote, !pane.isShowingSmartResults else { return }
        let origin = pane.viewOptionsURL
        let options = ViewOptionsController(
            format: pane.format, effective: pane.effectiveViewOptions,
            folderName: origin.lastPathComponent)
        Task { @MainActor in
            if let window = view.window { options.fit(in: window) }
            let response = await presentSheet(options.alert)
            guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else {
                return
            }
            let format = options.format
            if response == .alertSecondButtonReturn {
                setDefaultViewFormat(format)
            }
            rememberFormat(origin, format)
            if options.subfolders.state == .on { rememberSubtreeView(origin, format) }
            for side in [leftTabs, rightTabs] {
                for target in side.tabs
                where target.viewOptionsURL == origin
                    || (options.subfolders.state == .on
                        && target.viewOptionsURL.path.hasPrefix(
                            origin.path == "/" ? "/" : origin.path + "/"))
                {
                    target.reloadIfShowingListing()
                }
            }
        }
    }
}
