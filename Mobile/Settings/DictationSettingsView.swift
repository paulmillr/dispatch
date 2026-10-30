import Dictation
import SwiftUI

/// Chat dictation's engine: Apple's on-device recognizer, Whisper with a model downloaded from here (the composer's
/// microphone uses the one checked), or Parakeet with its models downloaded from here.
struct DictationSettingsView: View {
    @Bindable var settings: MobileSettings

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $settings.dictationEngine) {
                    ForEach(DictationEngine.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                switch settings.dictationEngine {
                case .apple: Text(AppleTranscriber.summary + ".")
                case .whisper: Text("Whisper runs on this \(MobileDevice.name) with a model you download.")
                case .parakeet:
                    Text("Parakeet runs on this \(MobileDevice.name)’s Neural Engine with models you download: English and 24 more European languages.")
                }
            }
            if settings.dictationEngine == .whisper {
                Section {
                    ForEach(WhisperModel.allCases) { model in
                        MobileDictationModelRow(model: .whisper(model), selected: settings.whisperModel == model) {
                            settings.whisperModel = model
                        }
                    }
                } header: {
                    Text("Whisper models")
                } footer: {
                    Text("Models download from huggingface.co and stay on this \(MobileDevice.name), out of its backups. Tap one to use it; a large model needs Wi-Fi and a few seconds more per message.")
                }
            } else if settings.dictationEngine == .parakeet {
                Section {
                    MobileDictationModelRow(model: .parakeet, selected: true) {}
                } header: {
                    Text("Parakeet model")
                } footer: {
                    Text("NVIDIA’s Parakeet TDT 0.6B v3 (CC BY 4.0) as Core ML models converted by FluidInference. They download from huggingface.co (Wi-Fi recommended) and stay on this \(MobileDevice.name), out of its backups.")
                }
            }
        }
        .navigationTitle("Dictation")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A dictation model (a Whisper model, or Parakeet's): a checkmark when dictation uses it, its size and what it suits,
/// and its download (the progress, Cancel, or Delete by swiping).
private struct MobileDictationModelRow: View {
    let model: DictationModel
    let selected: Bool
    let choose: () -> Void
    private var store: DictationModelStore { .shared }

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

    @ViewBuilder private func trailing(_ state: DictationModelStore.State) -> some View {
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

private extension DictationModelStore.State {
    var failed: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
