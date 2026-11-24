import AppKit
import PathemEngine
import UniformTypeIdentifiers

@MainActor
enum ThemeSubmissionDialog {
    private static let issueForm = URL(
        string: "https://github.com/Scarcrux/Pathem/issues/new?template=submit-theme.yml")!

    static func run(theme: ThemePreset) {
        let images = NSOpenPanel()
        images.title = L("themeSubmission.images", "Choose Marketplace Screenshots")
        images.message = L(
            "themeSubmission.imageHelp",
            "Choose 1–3 PNG or JPEG screenshots you intend to share publicly.")
        images.allowedContentTypes = [.png, .jpeg]
        images.allowsMultipleSelection = true
        guard images.runModal() == .OK else { return }

        do {
            guard (1...3).contains(images.urls.count) else {
                throw CommunityThemeError.invalidScreenshot
            }
            let screenshots = try images.urls.map {
                try CommunityThemeGallery.readSubmissionScreenshot(at: $0)
            }
            let package = try ThemePackage.encode(theme)
            prepare(title: theme.name, package: package, screenshots: screenshots)
        } catch {
            showThemeError(error)
        }
    }

    private static func prepare(title: String, package: Data, screenshots: [Data]) {
        let fields: [(String, NSTextField)] = [
            (L("themeSubmission.id", "Listing ID"), NSTextField(string: "")),
            (L("themeSubmission.revision", "Revision"), NSTextField(string: "1")),
            (L("themeSubmission.title", "Title"), NSTextField(string: title)),
            (L("themeSubmission.summary", "Summary"), NSTextField(string: "")),
            (L("themeSubmission.creator", "Creator credit"), NSTextField(string: "")),
            (L("themeSubmission.license", "License"), NSTextField(string: "")),
            (L("themeSubmission.source", "Source (optional)"), NSTextField(string: "")),
            (L("themeSubmission.tags", "Tags (optional)"), NSTextField(string: "")),
        ]
        let grid = NSGridView(
            views: fields.map { title, field in
                let label = NSTextField(labelWithString: title)
                field.setAccessibilityLabel(title)
                field.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
                return [label, field]
            })
        grid.rowSpacing = 6
        fields[0].1.placeholderString = "tidal-marsh"
        fields[7].1.placeholderString = L("themeSubmission.tagsHint", "Separate tags with commas")
        let dialog = NSAlert()
        dialog.messageText = L("themeSubmission.titleDialog", "Prepare Marketplace Submission")
        dialog.informativeText = L(
            "themeSubmission.help",
            "Use a lowercase listing ID with letters, digits, or hyphens. For an update, reuse the ID and increase the revision. Your submission will be public on GitHub."
        )
        grid.setFrameSize(grid.fittingSize)
        dialog.accessoryView = grid
        dialog.addButton(withTitle: L("themeSubmission.save", "Save and Continue…"))
        let cancel = dialog.addButton(withTitle: L("common.cancel", "Cancel"))
        cancel.keyEquivalent = "\u{1b}"
        dialog.window.initialFirstResponder = fields[0].1

        var values: [String] {
            fields.map { $0.1.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        while dialog.runModal() == .alertFirstButtonReturn {
            do {
                let input = values
                guard let revision = Int(input[1]), revision > 0 else {
                    throw CommunityThemeError.invalidListing
                }
                let submission = CommunityThemeRevision(
                    id: input[0], version: revision, title: input[2], summary: input[3],
                    creator: input[4], license: input[5], source: input[6].isEmpty ? nil : input[6],
                    tags: input[7].split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }, package: package, screenshots: screenshots)
                let data = try CommunityThemeGallery.encodeSubmission(submission)
                let exported = try JSONDecoder().decode(CommunityThemeRevision.self, from: data)
                if saveSubmission(data, submission: exported) { return }
            } catch {
                showThemeError(error)
            }
        }
    }

    private static func saveSubmission(_ data: Data, submission: CommunityThemeRevision) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(submission.id)-v\(submission.version).submission.json"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            showThemeError(error)
            return false
        }
        let next = NSAlert()
        next.messageText = L("themeSubmission.ready", "Submission Ready")
        next.informativeText = L(
            "themeSubmission.attach",
            "Attach the saved JSON to the GitHub issue form. Use your existing GitHub account. The file and issue will be public."
        )
        let previews = NSStackView(
            views: submission.screenshots.map { data in
                let view = NSImageView()
                view.image = NSImage(data: data)
                view.imageScaling = .scaleProportionallyUpOrDown
                view.widthAnchor.constraint(equalToConstant: 154).isActive = true
                view.heightAnchor.constraint(equalToConstant: 110).isActive = true
                return view
            })
        previews.setFrameSize(previews.fittingSize)
        next.accessoryView = previews
        next.addButton(withTitle: L("themeSubmission.open", "Open GitHub Form"))
        next.addButton(withTitle: L("themeSubmission.later", "Done for Now"))
        if next.runModal() == .alertFirstButtonReturn {
            var link = URLComponents(url: issueForm, resolvingAgainstBaseURL: false)
            link?.queryItems?.append(
                URLQueryItem(name: "title", value: "[Theme] \(submission.title)"))
            NSWorkspace.shared.open(link?.url ?? issueForm)
        }
        return true
    }
}
