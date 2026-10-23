import AppKit

/// Display-only reloads must not act like a new selection gesture. The verified
/// SDK clears native selection on raw reloads. Row/item identities must remain
/// unchanged here; directory/sort/group changes use each content's listing path.
@MainActor
enum PaneAppearanceReload {
    static func table(
        _ table: NSTableView, in scroll: NSScrollView,
        update: () -> Void, afterReload: () -> Void = {}
    ) {
        let selection = table.selectedRowIndexes
        let visibleRows = table.rows(in: table.visibleRect)
        let visibleSelection: Int?
        if visibleRows.location != NSNotFound, visibleRows.length > 0 {
            visibleSelection =
                selection.intersection(
                    IndexSet(integersIn: visibleRows.location..<NSMaxRange(visibleRows))
                ).first
        } else {
            visibleSelection = nil
        }
        let origin = scroll.contentView.bounds.origin
        update()
        table.reloadData()
        afterReload()
        table.layoutSubtreeIfNeeded()
        table.selectRowIndexes(selection, byExtendingSelection: false)
        restoreOrigin(origin, document: table, scroll: scroll)
        if let visibleSelection, !table.rect(ofRow: visibleSelection).intersects(table.visibleRect)
        {
            table.scrollRowToVisible(visibleSelection)
        }
    }

    static func collection(
        _ collection: NSCollectionView, in scroll: NSScrollView, update: () -> Void
    ) {
        let selection = collection.selectionIndexPaths
        let visibleSelection = selection.first {
            collection.layoutAttributesForItem(at: $0)?.frame.intersects(collection.visibleRect)
                == true
        }
        let origin = scroll.contentView.bounds.origin
        update()
        collection.reloadData()
        collection.layoutSubtreeIfNeeded()
        collection.selectionIndexPaths = selection
        restoreOrigin(origin, document: collection, scroll: scroll)
        if let visibleSelection,
            collection.layoutAttributesForItem(at: visibleSelection)?.frame.intersects(
                collection.visibleRect) == false
        {
            collection.scrollToItems(
                at: [visibleSelection],
                scrollPosition: [.nearestHorizontalEdge, .nearestVerticalEdge])
        }
    }

    private static func restoreOrigin(_ origin: NSPoint, document: NSView, scroll: NSScrollView) {
        let maxX = max(0, document.frame.width - scroll.contentView.bounds.width)
        let maxY = max(0, document.frame.height - scroll.contentView.bounds.height)
        let clip = scroll.contentView
        let minY = min(
            0, clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).minY)
        scroll.contentView.scroll(
            to: NSPoint(x: min(max(origin.x, 0), maxX), y: min(max(origin.y, minY), maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
