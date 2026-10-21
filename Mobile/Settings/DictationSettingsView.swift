import Dictation
import SwiftUI

/// Chat dictation's engine: Apple's on-device recognizer, or Whisper with a model downloaded from here (the composer's
/// microphone uses the one checked).
struct DictationSettingsView: View {
    @Bindable var settings: MobileSettings
    private var store: WhisperModelStore { .shared }

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $settings.dictationEngine) {
                    ForEach(DictationEngine.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text(settings.dictationEngine == .apple ? AppleTranscriber.summary + "."
                     : "Whisper runs on this \(MobileDevice.name) with a model you download.")
            }
            if settings.dictationEngine == .whisper {
                Section {
                    ForEach(WhisperModel.allCases) { model in
                        MobileWhisperModelRow(model: model, selected: settings.whisperModel == model) {
                            settings.whisperModel = model
                        }
                    }
                } header: {
                    Text("Whisper models")
                } footer: {
                    Text("Models download from huggingface.co and stay on this \(MobileDevice.name), out of its backups. Tap one to use it; a large model needs Wi-Fi and a few seconds more per message.")
                }
            }
        }
        .navigationTitle("Dictation")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A Whisper model: a checkmark when dictation uses it, its size and what it suits, and its download (the progress,
/// Cancel, or Delete by swiping).
private struct MobileWhisperModelRow: View {
    let model: WhisperModel
    let selected: Bool
    let choose: () -> Void
    private var store: WhisperModelStore { .shared }

    var body: some View {
        let state = store.state(model)
        Button {
            choose()
            if state == .absent || state.failed != nil { store.download(model) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(model.title).foregroundStyle(.primary)
                        Text(model.sizeLabel).font(.footnote).foregroundStyle(.secondary)
                    }
                    switch state {
                    case .downloading(let fraction):
                        ProgressView(value: fraction)
                    case .verifying:
                        Text("Verifying…").font(.footnote).foregroundStyle(.secondary)
                    case .failed(let message):
                        Text("Download failed: \(message)").font(.footnote).foregroundStyle(.red)
                    case .absent, .installed:
                        Text(model.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                trailing(state)
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .swipeActions {
            if state == .installed {
                Button("Delete", role: .destructive) { store.delete(model) }
            }
        }
    }

    @ViewBuilder private func trailing(_ state: WhisperModelStore.State) -> some View {
        switch state {
        case .downloading:
            Button("Cancel") { store.cancel(model) }.buttonStyle(.borderless)
        case .absent, .failed:
            Image(systemName: "arrow.down.circle").font(.title3).foregroundStyle(.tint)
                .accessibilityLabel("Download")
        case .verifying:
            ProgressView()
        case .installed:
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("In use") }
        }
    }
}

private extension WhisperModelStore.State {
    var failed: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
