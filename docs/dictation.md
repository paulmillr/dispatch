# Dictation

Chat dictation and voice commands on the Mac and iPhone. The engine is the local Swift package `Packages/Dictation`,
linked by both apps; shared app-side declarations in `Dispatch/Chat/DictationModels.swift` give each app process its
own model store and dictation instance (the package has no singletons). What
it downloads and stores is in [security](security.md#dictation).

## Engines

`DictationEngine` (`Packages/Dictation/Sources/Dictation/DictationModels.swift`):

- **Apple** (default): the system's on-device recognizer (`AppleTranscriber.swift`: SpeechAnalyzer with
  SpeechTranscriber where supported, otherwise DictationTranscriber; SFSpeechRecognizer on older Macs).
  The system manages the language asset and downloads it on first use if needed.
- **Whisper**: `Packages/WhisperEngine`, whisper.cpp 1.9.5 rewritten in Swift (ggml model files, mel, encoder and
  decoder, greedy decoding with temperature fallback). q8_0 models (`WhisperModel`: Small, Large v3 Turbo) download
  from Hugging Face with a pinned size and SHA-256.
  - Metal runs upstream ggml-metal kernels from `Kernels/` (`Kernels/PROVENANCE.md`), compiled at run time: Xcode 27
    ships no Metal compiler, so `.metal` sources in a target would break builds. `MetalBackend` builds every pipeline
    and runs a smoke test in `init`, so the Metal-or-CPU choice made then holds.
  - The CPU backend (Accelerate) holds every weight as Float32, about four times the file (Small 1 GB, Turbo 3 GB): a
    fallback on the Mac only; the iPhone has none.
  - Parity with whisper.cpp includes its quirk of flash attention over key/value buffers padded to 256 rows with no
    mask: `WhisperModel(attentionPadding:)` defaults to 256; 1 is exact attention.
  - An audio stretch is at most 28 s (`WhisperTranscriber.longest`).
- **Parakeet**: NVIDIA Parakeet TDT 0.6B v3 in FluidInference's Core ML conversion (`ParakeetModel`: the files
  FluidAudio loads for v3 with the int8 `Encoder_v2`, pinned to one repository revision, about 630 MB), decoded by our
  own greedy TDT loop (`ParakeetTranscriber`); no FluidAudio code. Its encoder takes a fixed 15 s window, so stretches
  are cut at 14 s (`StretchRecognizer`). The first load compiles for the Neural Engine (several seconds, once).

## In the composer

The microphone beside Send dictates one message: what it hears shows in the draft, a second click inserts it, Return
sends it and Escape cancels. Conversation mode, which goes on listening and reads replies aloud (Read replies aloud,
on by default), starts only when chosen by name: the microphone's right-click menu, or a tap of the voice key (holding
it dictates one message).

## Voice commands

A command starts with a wake word, "Dispatch" or "Captain" by default (user-editable in Settings › Features › Dictation;
`VoiceCommand.defaultWakeWords`). Wake words need two syllables: both recognizers drop or mishear a short word that opens
a sentence ("Dash", "Helm", "Deck", "Patch" all failed). Both also hear "tab two" as "tattoo"; the grammar maps it.
Replies read aloud are half-duplex: the microphone is muted while speaking (no echo cancellation).
On the Mac they are read in the best voice installed for the system's language (`VoiceConversation.voice`): a Premium
one, else an Enhanced one, the language's region first, unless the system's own voice is as good. The iPhone has
Settings › Chat › Voice instead (docs/ios.md).
A failure ("Dispatch can't use the microphone…") shows where dictation was started, in the composer's footer or the
voice note over the window, until clicked or for 10 s on the Mac (`dictationErrorTimeout`); Settings keeps its own.

## Testing

`swift test` in `Packages/Dictation` and in `Packages/WhisperEngine`, on the Mac. Engine cases skip without their models:

- `DISPATCH_WHISPER_MODELS`: a folder holding the Whisper model files (`ggml-small-q8_0.bin` for the speech tests).
- `DISPATCH_PARAKEET_MODELS`: a folder holding `parakeet-tdt-0.6b-v3/`.
- Apple's speech test follows the current system locale and skips unless it is English. On macOS 26+, it needs that
  locale's SpeechTranscriber or DictationTranscriber asset already installed. A model the system already has reads as
  merely supported until the process makes an asset installation request (a reservation), which the test makes
  without downloading. Older Macs need speech-recognition authorization and an available on-device recognizer.

The speech tests feed `say` recordings through `Dictation.input`. The Mac app's side is `DispatchTests/DictationTests`.

**Parity with whisper.cpp.** WhisperEngine was checked against whisper.cpp 1.9.5 itself (all three test models, tiny
f16, tiny q8_0 and small q8_0, on both backends) while whisper.cpp was still vendored as a C target. To repeat that
check, build upstream whisper.cpp 1.9.5 as a package target beside WhisperEngine and compare per decode step. whisper.cpp fills only the last token's logits for a batch, `whisper_n_len` is the unpadded
frame count, and `whisper_set_mel` injects a mel computed by us, so both sides start from the same input. Language
detection deliberately considers 100 language slots (slot 99 is "translate" on 51865-token models), as whisper.cpp does.
Release timings (4.4 s sentence, Small q8_0, M-series Mac): Metal 0.105 s against whisper.cpp's 0.099 s; CPU backend
0.69 s.
