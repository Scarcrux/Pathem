import Foundation
import PathemEngine

/// The app-wide choice of what leaving a document with unsaved markup does, set from
/// Preferences. Off (the default) asks; on saves without asking.
@MainActor
enum MarkupLeaveSettings {
    private(set) static var savesAutomatically = false

    static func apply(_ prefs: Preferences) { savesAutomatically = prefs.autosaveMarkup }

    #if DEBUG
    static func debugSet(savesAutomatically value: Bool) { savesAutomatically = value }
    #endif
}

extension BrowserViewController {
    /// Settle unsaved markup in every tab of both panes. False means the user cancelled or a
    /// save failed, and the window close or quit that asked must not go ahead.
    func prepareDocumentsToClose() -> Bool {
        for side in [leftTabs, rightTabs] {
            for pane in side.tabs {
                guard pane.prepareViewerToClose() else { return false }
            }
        }
        return true
    }
}
