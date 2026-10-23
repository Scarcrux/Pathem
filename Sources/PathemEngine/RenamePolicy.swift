import Foundation

public enum RenamePolicy {
    /// Case-only extension changes do not change type. Directories and dotfile basenames
    /// are not inferred to have an extension from their leading dot.
    public static func changesExtension(from old: String, to new: String, isDirectory: Bool) -> Bool
    {
        // Adding the first extension (e.g. a newly created untitled file -> notes.txt)
        // does not replace an existing type and must not interrupt the create/rename flow.
        guard !isDirectory, !(old as NSString).pathExtension.isEmpty else { return false }
        return (old as NSString).pathExtension.lowercased()
            != (new as NSString).pathExtension.lowercased()
    }
}
