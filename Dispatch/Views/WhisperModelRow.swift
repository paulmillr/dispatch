import Dictation
import SwiftUI

/// A Whisper model in Settings: its name, what it is good for and its size, a checkmark when dictation uses it, and
/// its download (Download, the progress with Cancel, or Delete). Clicking a downloaded model chooses it; clicking one
/// not yet downloaded chooses it and starts its download.
struct WhisperModelRow: View {
    @Environment(\.appTypography) private var typography
    let model: WhisperModel
    let selected: Bool
    let choose: () -> Void
    private var store: WhisperModelStore { .shared }

    var body: some View {
        let state = store.state(model)
        HStack(spacing: 10) {
            Button {
                choose()
                if state == .absent || isFailed(state) { store.download(model) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Chrome.accent : SettingsControlStyle.detail)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(model.title)
                            Text(model.sizeLabel).font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                        }
                        Text(detail(state)).font(typography.font(offset: -1.5))
                            .foregroundStyle(isFailed(state) ? Color.red : SettingsControlStyle.detail)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("settings-whisper-\(model.rawValue)")
            action(state)
        }
    }

    private func detail(_ state: WhisperModelStore.State) -> String {
        switch state {
        case .failed(let message): "Download failed: \(message)"
        case .installed where selected: description + " · in use"
        default: description
        }
    }

    /// The model's description, lowercase like the rest of Settings (the iPhone shows it as a sentence).
    private var description: String { model.detail.prefix(1).lowercased() + model.detail.dropFirst() }

    @ViewBuilder private func action(_ state: WhisperModelStore.State) -> some View {
        switch state {
        case .absent, .failed:
            Button("Download") { store.download(model) }
                .accessibilityIdentifier("settings-whisper-\(model.rawValue)-download")
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction).frame(width: 90)
                Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    .frame(width: 34, alignment: .trailing)
                Button("Cancel") { store.cancel(model) }
            }
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Verifying…").font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
            }
        case .installed:
            Button("Delete") { store.delete(model) }
                .accessibilityIdentifier("settings-whisper-\(model.rawValue)-delete")
        }
    }

    private func isFailed(_ state: WhisperModelStore.State) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
