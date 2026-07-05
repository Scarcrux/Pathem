import AppKit
import PathemEngine

/// Composes a file's display name with its git-status badge and tag color dots into one
/// attributed string. Shared by the list and column views so both render identically -- add a
/// new decoration here once and every view that uses it gets it.
enum FileNameDecoration {
    /// Color + one-letter badge for a git working-tree state.
    static func gitBadge(_ state: GitFileState) -> (letter: String, color: NSColor) {
        switch state {
        case .modified: return ("M", .systemOrange)
        case .added: return ("A", .systemGreen)
        case .deleted: return ("D", .systemRed)
        case .renamed: return ("R", .systemBlue)
        case .untracked: return ("?", .systemGray)
        case .conflicted: return ("!", .systemRed)
        }
    }

    /// An optional leading colored git-state letter, the name, then a colored dot per tag.
    static func decoratedName(
        _ name: String, git: GitFileState?, dots colors: [FileTag.Color], size: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if let git {
            let badge = gitBadge(git)
            result.append(
                NSAttributedString(
                    string: "\(badge.letter) ",
                    attributes: [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: badge.color]))
        }
        result.append(
            NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: size)]))
        appendDots(colors, to: result, size: size)
        return result
    }

    private static func appendDots(
        _ colors: [FileTag.Color], to result: NSMutableAttributedString, size: CGFloat
    ) {
        let diameter = size - 2
        for color in colors {
            let attachment = NSTextAttachment()
            attachment.image = TagColors.dot(color, diameter: diameter)
            attachment.bounds = NSRect(x: 0, y: -1, width: diameter, height: diameter)
            result.append(NSAttributedString(string: " "))
            result.append(NSAttributedString(attachment: attachment))
        }
    }
}
