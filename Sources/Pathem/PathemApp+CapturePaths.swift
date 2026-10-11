#if DEBUG
import Foundation

extension PathemApp {
    /// E2E owns a unique capture directory; legacy standalone shot commands retain /tmp.
    static var captureDirectory: String {
        ProcessInfo.processInfo.environment["PATHEM_CAPTURE_DIR"] ?? "/tmp"
    }
    static func capturePath(_ name: String) -> String {
        URL(fileURLWithPath: captureDirectory, isDirectory: true).appendingPathComponent(name).path
    }
}
#endif
