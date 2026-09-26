import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    fputs("usage: window_probe.swift PID\n", stderr)
    exit(2)
}

// Read-only external observation of on-screen windows. Unlike System Events UI scripting,
// this does not control another process and therefore does not require Accessibility access.
let rows =
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
let visible = rows.filter { row in
    let owner = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue
    return owner == pid && layer == 0
}
print(visible.count)
