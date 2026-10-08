import SwiftUI

/// Records a key group's modifiers in Settings › Keys: click (or Space), hold any of ⌃ ⌥ ⇧ ⌘ and
/// release them, or press a key while holding them. ⌫ unbinds the group; Esc or clicking elsewhere cancels.
struct KeyGroupRecorder: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.appTypography) private var typography
    let title: String
    let modifiers: NSEvent.ModifierFlags
    /// The keys the modifiers go with, as "1…9".
    let digits: String
    let record: (NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> RecorderView { RecorderView() }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.modifiers = modifiers
        view.digits = digits
        view.record = record
        view.isEnabled = isEnabled
        view.font = AppFont.native(size: typography.size(offset: -0.5))
        // Key legends match the shortcut sheet and sidebar; the prompt stays in the UI font.
        view.keyFont = AppFont.nativeShortcut(size: typography.size(offset: -0.5))
        view.setAccessibilityLabel(title)
        view.setAccessibilityIdentifier("settings-keys-\(title)")
        view.needsDisplay = true
    }

    final class RecorderView: NSView {
        var modifiers: NSEvent.ModifierFlags = []
        var digits = ""
        var record: (NSEvent.ModifierFlags) -> Void = { _ in }
        var isEnabled = true { didSet { if !isEnabled { recording = false } } }
        var font = NSFont.systemFont(ofSize: 12)
        var keyFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        private(set) var recording = false { didSet { held = []; needsDisplay = true } }
        /// Every modifier held since recording began; recorded once they are all released.
        private var held: NSEvent.ModifierFlags = []

        override var acceptsFirstResponder: Bool { isEnabled }
        override var intrinsicContentSize: NSSize { NSSize(width: 180, height: 27) }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            if recording { recording = false; return }
            window?.makeFirstResponder(self)
            recording = true
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            return super.resignFirstResponder()
        }

        override func flagsChanged(with event: NSEvent) {
            guard recording else { return super.flagsChanged(with: event) }
            let now = event.modifierFlags.intersection(KeyGroups.modifierMask)
            if now.isEmpty, !held.isEmpty { finish(held) } else { held.formUnion(now); needsDisplay = true }
        }

        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection(KeyGroups.modifierMask)
            guard recording else {
                if isEnabled, flags.isEmpty, event.keyCode == 49 { recording = true } else { super.keyDown(with: event) }
                return
            }
            if flags.isEmpty {
                if event.keyCode == 53 { recording = false }
                // Delete (or Forward Delete) unbinds the group: no modifiers, no shortcut.
                else if event.keyCode == 51 || event.keyCode == 117 { finish([]) }
            } else { finish(flags) }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            // While recording, ⌘W and the menus' chords are what is being recorded.
            guard recording, event.type == .keyDown, window?.firstResponder === self else {
                return super.performKeyEquivalent(with: event)
            }
            keyDown(with: event)
            return true
        }

        private func finish(_ flags: NSEvent.ModifierFlags) {
            recording = false
            record(flags)
        }

        private var label: String {
            guard recording else { return modifiers.isEmpty ? "None" : KeyGroups.symbols(modifiers) + digits }
            return held.isEmpty ? "Hold modifiers…" : KeyGroups.symbols(held) + digits
        }

        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            NSColor(SettingsControlStyle.fill).setFill(); shape.fill()
            NSColor(recording ? Chrome.accent : SettingsControlStyle.border).setStroke()
            shape.lineWidth = recording ? 1.5 : 1; shape.stroke()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: recording && held.isEmpty ? font : keyFont,
                .foregroundColor: NSColor(recording && held.isEmpty ? Chrome.palette.detail : Chrome.ink)
                    .withAlphaComponent(isEnabled ? 1 : 0.5),
            ]
            let text = label as NSString, height = text.size(withAttributes: attributes).height
            text.draw(in: NSRect(x: rect.minX + 9, y: rect.midY - height / 2, width: max(0, rect.width - 18), height: height),
                      withAttributes: attributes)
        }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityValue() -> Any? { label }
        override func accessibilityPerformPress() -> Bool {
            guard isEnabled else { return false }
            window?.makeFirstResponder(self)
            recording = true
            return true
        }
    }
}
