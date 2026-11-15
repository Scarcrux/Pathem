// Inspect or switch the main display's mode, for capturing 2x screenshots on a 1x display.
//
//   xcrun swiftc -O scripts/display-mode.swift -o /tmp/display-mode
//   /tmp/display-mode current             # prints "<modeID> <points> <pixels> <Hz>"
//   /tmp/display-mode find 3840 1080      # a HiDPI (2x) mode of that point size, if any
//   /tmp/display-mode set <modeID>        # for this login session only
//
// A 1x display usually offers scaled HiDPI modes. In one, scripts/site-shots.sh captures a
// 1440x900 pt window as 2880x1800 px. Always record `current` first and set it back
// afterwards; the change shrinks everything on screen while it is in effect.
import CoreGraphics
import Foundation

let display = CGMainDisplayID()
let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(display, opts) as? [CGDisplayMode]) ?? []
let args = CommandLine.arguments
func describe(_ m: CGDisplayMode) -> String {
    "\(m.ioDisplayModeID) \(m.width)x\(m.height)pt \(m.pixelWidth)x\(m.pixelHeight)px \(m.refreshRate)Hz"
}
switch args.count > 1 ? args[1] : "" {
case "current":
    if let m = CGDisplayCopyDisplayMode(display) { print(describe(m)) }
case "find":
    let w = Int(args[2])!
    let h = Int(args[3])!
    let current = CGDisplayCopyDisplayMode(display)
    let hits = modes.filter { $0.width == w && $0.height == h && $0.pixelWidth == w * 2 }
        .sorted {
            abs($0.refreshRate - (current?.refreshRate ?? 60))
                < abs($1.refreshRate - (current?.refreshRate ?? 60))
        }
    if let m = hits.first { print(describe(m)) } else { exit(1) }
case "set":
    let id = Int32(args[2])!
    guard let m = modes.first(where: { $0.ioDisplayModeID == id }) else {
        print("no such mode")
        exit(1)
    }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else {
        print("begin failed")
        exit(1)
    }
    CGConfigureDisplayWithDisplayMode(config, display, m, nil)
    let result = CGCompleteDisplayConfiguration(config, .forSession)
    print(result == .success ? "set \(describe(m))" : "set failed \(result.rawValue)")
    exit(result == .success ? 0 : 1)
default: exit(2)
}
