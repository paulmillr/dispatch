import Dictation

/// The iPhone app's chat dictation (Packages/Dictation): one model store in the app's support folder, and one
/// dictation at a time for every composer.
extension WhisperModelStore {
    static let shared = WhisperModelStore(directory: Home.support.appendingPathComponent("Whisper"))
}

extension Dictation {
    static let shared = Dictation(models: .shared)
}
