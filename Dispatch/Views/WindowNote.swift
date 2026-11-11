import AppKit
import Observation
import SwiftUI

/// A short note over the top of the window for an action that did nothing, saying why ("Grid needs 4 tabs"); it goes by
/// itself after a few seconds, or when clicked. One at a time: a new note replaces the last.
@MainActor @Observable
final class WindowNotes {
    static let shared = WindowNotes()
    private(set) var text: String?
    @ObservationIgnored private var generation = 0
    static let duration: Duration = .seconds(4)

    /// Shows `text` with the system beep: the key or click that led here did nothing else.
    func show(_ text: String, beep: Bool = true) {
        if beep { NSSound.beep() }
        self.text = text
        generation += 1
        let shown = generation
        Task { [weak self] in
            try? await System.sleep(for: Self.duration, "window.note")
            guard let self, self.generation == shown else { return }
            self.text = nil
        }
    }

    func dismiss() { text = nil; generation += 1 }
}

struct WindowNote: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var notes: WindowNotes { .shared }

    var body: some View {
        if let text = notes.text {
            Button { notes.dismiss() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(Chrome.palette.secondary)
                    Text(text).lineLimit(2).multilineTextAlignment(.leading)
                }
                .font(typography, .body).foregroundStyle(Chrome.ink)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .liquidGlass(in: Capsule(), fallback: Chrome.sidebar, interactive: true)
                .frame(maxWidth: 520)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .padding(.top, 10)
            .transition(.opacity.animation(InterfaceMotion.animation(reduce: reduceMotion)))
            .accessibilityIdentifier("window-note")
            .onAppear { NSAccessibility.post(element: NSApp.mainWindow as Any, notification: .announcementRequested,
                                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue]) }
        }
    }
}
