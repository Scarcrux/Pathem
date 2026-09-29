import Darwin
import Foundation

/// A bounded, inert projection of a Jupyter notebook for Pathem's read-only viewer.
/// Notebook HTML and JavaScript are never interpreted: Markdown, code, and text outputs are
/// rendered as plain text, so previewing an untrusted notebook cannot execute its payloads.
public enum NotebookPreview {
    public static let maximumFileBytes = 16 * 1024 * 1024
    public static let maximumCells = 200
    public static let maximumCharacters = 240_000

    public enum PreviewError: Error, Equatable, Sendable {
        case tooLarge
        case invalidNotebook
        case unsupportedFile
        case unreadable
    }

    public struct Document: Equatable, Sendable {
        public let text: String
        public let cellCount: Int
        public let truncated: Bool
    }

    /// Open one descriptor, prove it is a regular file, and read no more than the public cap.
    /// `O_NONBLOCK` prevents a path ending in `.ipynb` from hanging on a FIFO or device before the
    /// `fstat` rejection. Opening once also removes the metadata-check/read TOCTOU gap.
    public static func document(at url: URL) throws -> Document {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw PreviewError.unreadable }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw PreviewError.unreadable }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw PreviewError.unsupportedFile }
        guard info.st_size <= maximumFileBytes else { throw PreviewError.tooLarge }

        var data = Data()
        data.reserveCapacity(min(Int(info.st_size), maximumFileBytes))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= maximumFileBytes {
            let remaining = maximumFileBytes + 1 - data.count
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, min(rawBuffer.count, remaining))
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw PreviewError.unreadable
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximumFileBytes else { throw PreviewError.tooLarge }
        return try document(from: data)
    }

    /// Parse and render a notebook without executing or interpreting any rich output.
    public static func document(from data: Data) throws -> Document {
        guard data.count <= maximumFileBytes else { throw PreviewError.tooLarge }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawCells = root["cells"] as? [[String: Any]]
        else { throw PreviewError.invalidNotebook }

        var text = ""
        var truncated = rawCells.count > maximumCells
        var renderedCells = 0
        for (offset, cell) in rawCells.prefix(maximumCells).enumerated() {
            let kind = (cell["cell_type"] as? String) ?? "unknown"
            let source = joinedText(cell["source"])
            var heading = kind == "code" ? "Code cell" : kind.capitalized + " cell"
            if kind == "code", let count = cell["execution_count"], !(count is NSNull) {
                heading += " [\(count)]"
            }
            var body = source
            if kind == "code", let outputs = cell["outputs"] as? [[String: Any]] {
                let rendered = outputs.compactMap(renderOutput).filter { !$0.isEmpty }
                if !rendered.isEmpty { body += "\n\nOutput\n" + rendered.joined(separator: "\n") }
            }
            let section = "\(offset + 1). \(heading)\n\(body)".trimmingCharacters(
                in: .whitespacesAndNewlines)
            let separator = text.isEmpty ? "" : "\n\n────────────────────────\n\n"
            let remaining = maximumCharacters - text.count
            guard remaining > 0 else {
                truncated = true
                break
            }
            let addition = separator + section
            if addition.count > remaining {
                text += String(addition.prefix(remaining))
                truncated = true
                break
            }
            text += addition
            renderedCells += 1
        }
        if truncated {
            let notice =
                "\n\nPreview truncated — open the notebook in its editor for the complete document."
            if notice.count <= maximumCharacters - text.count { text += notice }
        }
        return Document(
            text: text.isEmpty ? "This notebook has no cells." : text,
            cellCount: renderedCells, truncated: truncated)
    }

    private static func joinedText(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let values = value as? [String] { return values.joined() }
        return ""
    }

    private static func renderOutput(_ output: [String: Any]) -> String? {
        if let text = output["text"] { return joinedText(text) }
        if let data = output["data"] as? [String: Any], let plain = data["text/plain"] {
            return joinedText(plain)
        }
        if let name = output["ename"] as? String {
            let value = output["evalue"] as? String ?? ""
            return value.isEmpty ? name : "\(name): \(value)"
        }
        return nil
    }
}
