import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

let tccPath = ("~/Library/Application Support/com.apple.TCC/TCC.db" as NSString)
    .expandingTildeInPath
let tccExists = FileManager.default.fileExists(atPath: tccPath)
let descriptor = open(tccPath, O_RDONLY)
let fullDiskAccess = !tccExists || descriptor >= 0
if descriptor >= 0 { close(descriptor) }

print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "not-granted")")
print("Full Disk Access: \(fullDiskAccess ? "granted" : "not-granted")")
print("Screen Recording: \(CGPreflightScreenCaptureAccess() ? "granted" : "not-granted")")
print("RESULT: PASS  permission states reported without prompting")
