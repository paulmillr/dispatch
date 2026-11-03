import Dictation
import Foundation

/// The app's chat dictation (Packages/Dictation): one model store in Dispatch's support folder (Whisper/ and
/// Parakeet/), and one dictation at a time for every composer.
extension DictationModelStore {
    static let shared = DictationModelStore(whisper: Home.support.appendingPathComponent("Whisper"),
                                            parakeet: Home.support.appendingPathComponent("Parakeet"))
}

extension Dictation {
    static let shared = Dictation(models: .shared)
}
