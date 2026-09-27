import ApplicationServices
import Foundation

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    print("RESULT: FAIL  usage: accessibility_probe.swift PID")
    exit(1)
}
guard AXIsProcessTrusted() else {
    print("RESULT: SKIP  Accessibility permission is not granted to the runner host")
    exit(0)
}

let app = AXUIElementCreateApplication(pid)
guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty else {
    print("RESULT: FAIL  Pathem exposes no accessibility window")
    exit(1)
}

var queue = windows
var visited = 0
var actionable = 0
var labeledActionable = 0
while !queue.isEmpty, visited < 5_000 {
    let element = queue.removeFirst()
    visited += 1
    let role = stringAttribute(element, kAXRoleAttribute) ?? ""
    if [kAXButtonRole, kAXTextFieldRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXMenuButtonRole]
        .contains(role)
    {
        actionable += 1
        let label =
            stringAttribute(element, kAXDescriptionAttribute)
            ?? stringAttribute(element, kAXTitleAttribute)
            ?? stringAttribute(element, kAXValueAttribute)
        if label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            labeledActionable += 1
        }
    }
    if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
        queue.append(contentsOf: children)
    }
}

guard visited >= 20, actionable >= 5, labeledActionable >= 5 else {
    print(
        "RESULT: FAIL  shallow accessibility tree: nodes=\(visited) actionable=\(actionable) labeled=\(labeledActionable)"
    )
    exit(1)
}
print(
    "RESULT: PASS  external AX tree exposes \(visited) nodes and \(labeledActionable)/\(actionable) labeled controls"
)
