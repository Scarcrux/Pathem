import AppKit
import PathemEngine

/// The popover behind the status bar's selection summary: a stacked bar of the selection's
/// kinds (tinted from the theme accent) with a count and size row for each.
@MainActor
enum SelectionSummaryPopover {
    /// Per-kind colors: the theme accent's hue, stepped around the wheel so neighbors differ,
    /// with "other" and folders in neutral grays.
    static func color(for kind: FileKindBucket, accent: NSColor) -> NSColor {
        let base = accent.usingColorSpace(.sRGB) ?? .systemBlue
        var hue: CGFloat = 0
        var sat: CGFloat = 0
        var bri: CGFloat = 0
        base.getHue(&hue, saturation: &sat, brightness: &bri, alpha: nil)
        let steps: [FileKindBucket: CGFloat] = [
            .image: 0, .video: 0.14, .audio: 0.28, .document: 0.42, .code: 0.56, .archive: 0.70,
            .app: 0.84,
        ]
        switch kind {
        case .folder: return NSColor(white: 0.55, alpha: 1)
        case .other: return NSColor(white: 0.72, alpha: 1)
        default:
            let h = (hue + (steps[kind] ?? 0)).truncatingRemainder(dividingBy: 1)
            return NSColor(hue: h, saturation: max(0.45, min(0.8, sat)), brightness: 0.85, alpha: 1)
        }
    }

    static func title(for kind: FileKindBucket) -> String {
        switch kind {
        case .folder: return L("kind.folder", "Folders")
        case .app: return L("kind.app", "Apps")
        case .image: return L("kind.image", "Images")
        case .video: return L("kind.video", "Video")
        case .audio: return L("kind.audio", "Audio")
        case .document: return L("kind.document", "Documents")
        case .code: return L("kind.code", "Code")
        case .archive: return L("kind.archive", "Archives")
        case .other: return L("kind.other", "Other")
        }
    }

    static func makeView(
        summary: SelectionSummary, accent: NSColor, formatBytes: (Int64) -> String
    ) -> NSView {
        let bar = StackedBar(
            parts: summary.slices.map {
                (Double(max($0.bytes, 0)), Double($0.count), color(for: $0.kind, accent: accent))
            })
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 12).isActive = true

        var rows: [NSView] = []
        let heading = NSTextField(
            labelWithString: String(
                format: L("summary.heading", "%d of %d selected"), summary.selectedCount,
                summary.totalCount))
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        rows.append(heading)
        rows.append(bar)
        for slice in summary.slices {
            let dot = ColorDot(color: color(for: slice.kind, accent: accent))
            let name = NSTextField(labelWithString: title(for: slice.kind))
            name.font = .systemFont(ofSize: 11)
            let count = NSTextField(labelWithString: "\(slice.count)")
            count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            count.textColor = .secondaryLabelColor
            count.alignment = .right
            let size = NSTextField(labelWithString: formatBytes(slice.bytes))
            size.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            size.textColor = .secondaryLabelColor
            size.alignment = .right
            for field in [count, size] { field.translatesAutoresizingMaskIntoConstraints = false }
            count.widthAnchor.constraint(equalToConstant: 48).isActive = true
            size.widthAnchor.constraint(equalToConstant: 72).isActive = true
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let row = NSStackView(views: [dot, name, spacer, count, size])
            row.spacing = 6
            row.alignment = .centerY
            rows.append(row)
        }
        var footnotes: [String] = []
        if summary.unmeasuredFolders > 0 {
            footnotes.append(
                summary.unmeasuredFolders == 1
                    ? L("summary.unmeasuredOne", "1 folder not measured yet")
                    : String(
                        format: L("summary.unmeasured", "%d folders not measured yet"),
                        summary.unmeasuredFolders))
        }
        if summary.isApproximate {
            footnotes.append(
                String(
                    format: L("summary.approximate", "Approximate: based on the first %d items"),
                    SelectionSummary.approximateCap))
        }
        for note in footnotes {
            let label = NSTextField(wrappingLabelWithString: note)
            label.font = .systemFont(ofSize: 10)
            label.textColor = .secondaryLabelColor
            rows.append(label)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for row in rows.dropFirst(1) {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: 252).isActive = true
        }
        stack.setAccessibilityLabel(heading.stringValue)
        return stack
    }

    /// Open (or re-point) the popover under the status label.
    static func show(
        _ popover: NSPopover, summary: SelectionSummary, accent: NSColor, relativeTo anchor: NSView,
        formatBytes: (Int64) -> String
    ) {
        let controller = NSViewController()
        controller.view = makeView(summary: summary, accent: accent, formatBytes: formatBytes)
        controller.view.layoutSubtreeIfNeeded()
        popover.contentViewController = controller
        popover.behavior = .transient
        if !popover.isShown {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        }
    }

    #if DEBUG
    /// Render the popover content to a PNG (PATHEM_SUMMARY_SHOT=<png>). The bubble itself is
    /// drawn by AppKit, so this paints a backing to show the content's edges. Sample data only.
    static func debugRender(to path: String, appearance: NSAppearance?) {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        func file(_ name: String, _ size: Int64) -> FileEntry {
            FileEntry(name: name, isDirectory: false, size: size, modificationDate: day)
        }
        var selected = [
            file("IMG_0001.heic", 3_400_000), file("IMG_0002.heic", 4_100_000),
            file("trip.mov", 812_000_000), file("song.m4a", 9_800_000),
            file("report.pdf", 2_300_000), file("main.swift", 14_000),
            file("backup.zip", 45_000_000), file("blob.xyz", 800),
        ]
        selected.append(
            FileEntry(name: "Photos", isDirectory: true, size: 0, modificationDate: day))
        selected.append(FileEntry(name: "Notes", isDirectory: true, size: 0, modificationDate: day))
        let summary = SelectionSummary.summarize(
            selected: selected, totalCount: 120,
            folderSize: { $0.name == "Photos" ? 220_000_000 : nil })
        let view = makeView(
            summary: summary, accent: ThemeManager.shared.accent,
            formatBytes: { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
        view.appearance = appearance
        view.layoutSubtreeIfNeeded()
        view.setFrameSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        view.wantsLayer = true
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        view.layer?.cornerRadius = 10
        guard view.bounds.width > 1,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print(
                "SUMMARY SHOT: \(Int(view.bounds.width))x\(Int(view.bounds.height)) slices=\(summary.slices.count)"
            )
        }
    }
    #endif

    private final class ColorDot: NSView {
        let color: NSColor
        init(color: NSColor) {
            self.color = color
            super.init(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
            translatesAutoresizingMaskIntoConstraints = false
            widthAnchor.constraint(equalToConstant: 8).isActive = true
            heightAnchor.constraint(equalToConstant: 8).isActive = true
        }
        required init?(coder: NSCoder) { fatalError() }
        override func draw(_ dirtyRect: NSRect) {
            color.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
    }

    /// Segments sized by bytes; when every size is zero, by count.
    private final class StackedBar: NSView {
        let parts: [(bytes: Double, count: Double, color: NSColor)]
        init(parts: [(Double, Double, NSColor)]) {
            self.parts = parts.map { (bytes: $0.0, count: $0.1, color: $0.2) }
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func draw(_ dirtyRect: NSRect) {
            let clip = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
            NSColor.quaternaryLabelColor.setFill()
            clip.fill()
            clip.addClip()
            let byBytes = parts.reduce(0) { $0 + $1.bytes } > 0
            let total = parts.reduce(0) { $0 + (byBytes ? $1.bytes : $1.count) }
            guard total > 0 else { return }
            var x: CGFloat = 0
            for part in parts {
                let weight = byBytes ? part.bytes : part.count
                // A hairline minimum keeps tiny kinds visible next to a huge one.
                let width = max(weight / total * bounds.width, weight > 0 ? 2 : 0)
                part.color.setFill()
                NSRect(x: x, y: 0, width: width, height: bounds.height).fill()
                x += width
            }
        }
    }
}

/// The status bar's text. A click opens the kind breakdown when `onClick` takes it.
final class SummaryStatusLabel: NSTextField {
    /// Returns true when the click was used.
    var onClick: (() -> Bool)?
    override func mouseDown(with event: NSEvent) {
        if onClick?() != true { super.mouseDown(with: event) }
    }
    override func resetCursorRects() {
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
