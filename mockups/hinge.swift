import AppKit
import ApplicationServices

// Folds or unfolds the iPhone Duo simulator for shoot.py: presses DeviceHub's hinge button ("Closed", "Partially
// Open", "Open") through the accessibility API, which sees DeviceHub's window where System Events does not
// (docs/ios.md, Simulator window). `hinge Open <DeviceHub pid>`; the process running it needs Accessibility access.
let want = CommandLine.arguments.dropFirst().first ?? "Open"
guard AXIsProcessTrusted() else { print("not trusted for accessibility"); exit(2) }
guard let pidText = CommandLine.arguments.dropFirst(2).first, let pid = pid_t(pidText) else { print("usage: hinge Open <pid>"); exit(3) }
let root = AXUIElementCreateApplication(pid)
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?; AXUIElementCopyAttributeValue(e, name as CFString, &value); return value
}
var found = false
func walk(_ e: AXUIElement, _ depth: Int) {
    guard depth < 40, !found else { return }
    let role = attr(e, kAXRoleAttribute) as? String ?? ""
    let title = (attr(e, kAXTitleAttribute) as? String) ?? (attr(e, kAXDescriptionAttribute) as? String) ?? ""
    if role.contains("Button"), title == want {
        found = AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
        print("pressed \(title): \(found)"); return
    }
    for child in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth + 1) }
}
for _ in 0..<5 where !found { walk(root, 0); if !found { Thread.sleep(forTimeInterval: 0.5) } }
if !found { print("no \(want) button"); exit(4) }
