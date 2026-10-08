import AppKit
import Metal

func fail(_ message: String) -> Never {
    fputs("VM preflight: \(message)\n", stderr)
    exit(1)
}

guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
      (session[kCGSessionOnConsoleKey as String] as? NSNumber)?.boolValue == true,
      (session[kCGSessionLoginDoneKey as String] as? NSNumber)?.boolValue == true else {
    fail("Tests must run in the guest's logged-in desktop session. Check the Tart guest LaunchAgent.")
}
if (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true {
    fail("The guest desktop is locked. Unlock the VM before testing.")
}
// Tart's display size is a hint. macOS can retain a smaller mode after boot;
// select the test mode explicitly before AppKit creates or sizes any windows.
let display = CGMainDisplayID()
let modes = CGDisplayCopyAllDisplayModes(display, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? []
let current = CGDisplayCopyDisplayMode(display)
// Support both the desktop baseline and a MacBook Air-sized Retina desktop.
// Keep the active profile when it already matches either supported size.
func supported(_ mode: CGDisplayMode) -> Bool {
    ((mode.width == 1920 && mode.height == 1080) || (mode.width == 1280 && mode.height == 832))
        && mode.pixelWidth == mode.width * 2 && mode.pixelHeight == mode.height * 2
}
guard let mode = current.flatMap({ supported($0) ? $0 : nil })
    ?? modes.filter(supported).max(by: { $0.width < $1.width }) else {
    // Tart derives a point-sized display's scale from the host's main screen
    // when the VM boots; a 1× main monitor yields a 1× guest with no such mode.
    fail("The guest needs a 1920 × 1080 or 1280 × 832 desktop at 2× Retina scale. Boot the VM while a Retina display is the host's main display.")
}
if current?.width != mode.width || current?.height != mode.height
    || current?.pixelWidth != mode.pixelWidth || current?.pixelHeight != mode.pixelHeight {
    var configuration: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
        fail("Could not begin configuring the guest display.")
    }
    guard CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil) == .success else {
        CGCancelDisplayConfiguration(configuration)
        fail("Could not select the guest's Retina display mode.")
    }
    // Keep the mode for the desktop session, but avoid resetting a display that
    // is already correct on every warm test run.
    guard CGCompleteDisplayConfiguration(configuration, .forSession) == .success else {
        fail("Could not keep the guest display mode for the test session.")
    }
}
guard let screen = NSScreen.main else { fail("The guest has no desktop display.") }
guard let device = MTLCreateSystemDefaultDevice() else { fail("The guest has no Metal device.") }
print("Guest display: \(screen.frame), scale \(screen.backingScaleFactor); Metal: \(device.name)")
