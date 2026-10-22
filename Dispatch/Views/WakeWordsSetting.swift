import Dictation
import SwiftUI

/// Settings › Dictation › Wake words: the words "Dispatch, …" commands start with, typed as a list and checked as you
/// type (`WakeWords`); a list with no usable word keeps the last one that had some. Try it listens once, with the
/// engine chosen above, and says what it heard and whether that was a command.
struct WakeWordsSetting: View {
    @Binding var words: [String]
    let engine: DictationEngine
    let model: WhisperModel
    @Environment(\.appTypography) private var typography
    @State private var text = ""
    @State private var checked = WakeWords.check("")
    @State private var trying = false
    @State private var heard = ""
    @State private var outcome: (text: String, ok: Bool)?
    private static let owner = "wake-word-test"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Dispatch, Captain", text: $text)
                    .textFieldStyle(.roundedBorder).font(typography.font(offset: -0.5))
                    .onChange(of: text) { _, value in apply(value) }
                    .accessibilityIdentifier("settings-wake-words")
                Button(trying ? "Stop" : "Try it") { trying ? Dictation.shared.cancel() : tryIt() }
                    .disabled(checked.words.isEmpty)
                    .accessibilityIdentifier("settings-wake-words-try")
            }
            ForEach(checked.problems + checked.warnings, id: \.self) { line in
                Label(line, systemImage: "exclamationmark.triangle").font(typography.font(offset: -1.5))
                    .foregroundStyle(SettingsControlStyle.detail)
            }
            if checked.words.isEmpty, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("No usable word: commands keep starting with “\(Self.title(words.first ?? "dispatch"))”.")
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
            }
            if trying {
                Text(heard.isEmpty ? "Listening · say “\(Self.title(checked.words.first ?? "dispatch")), send”" : heard)
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    .accessibilityIdentifier("settings-wake-words-heard")
            } else if let error = Dictation.shared.error(for: Self.owner) {
                Label(error, systemImage: "exclamationmark.triangle").font(typography.font(offset: -1.5))
                    .foregroundStyle(SettingsControlStyle.detail)
            } else if let outcome {
                Label(outcome.text, systemImage: outcome.ok ? "checkmark.circle" : "xmark.circle")
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    .accessibilityIdentifier("settings-wake-words-outcome")
            }
        }
        .padding(.bottom, 9)
        .onAppear {
            text = words.map(Self.title).joined(separator: ", ")
            checked = WakeWords.check(text)
        }
        // Restore default replaces the words from outside; typing only ever sets the words it checked.
        .onChange(of: words) { _, words in
            guard words != checked.words else { return }
            text = words.map(Self.title).joined(separator: ", ")
            checked = WakeWords.check(text)
            outcome = nil
        }
        .onDisappear { if trying { Dictation.shared.cancel() } }
    }

    private func apply(_ value: String) {
        checked = WakeWords.check(value)
        outcome = nil
        if !checked.words.isEmpty, checked.words != words { words = checked.words }
    }

    /// Listens for one utterance (stopping at its pause, or after 10 s of nothing).
    private func tryIt() {
        let wakeWords = checked.words
        trying = true
        heard = ""
        outcome = nil
        Dictation.shared.start(owner: Self.owner, engine: engine, model: model, continuous: true) { update in
            switch update {
            case .heard(let text):
                heard = text
            case .utterance(let text), .finished(let text):
                guard trying else { return }
                trying = false
                outcome = Self.judge(text, wakeWords: wakeWords)
                Dictation.shared.cancel()
            case .ended:
                trying = false
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(10))
            if trying, heard.isEmpty {
                trying = false
                outcome = ("Didn't hear anything", false)
                Dictation.shared.cancel()
            }
        }
    }

    static func judge(_ text: String, wakeWords: [String]) -> (text: String, ok: Bool) {
        switch VoiceCommand.read(text, wakeWords: wakeWords) {
        case .command: ("Heard “\(text)”: a command", true)
        case .unrecognized: ("Heard “\(text)”: the wake word, but no command it knows", false)
        case .text: ("Heard “\(text)”: no wake word there. It may be heard as another word; try a longer one", false)
        }
    }

    /// "dispatch" as it is said in a sentence: "Dispatch".
    static func title(_ word: String) -> String { word.prefix(1).uppercased() + word.dropFirst() }
}
