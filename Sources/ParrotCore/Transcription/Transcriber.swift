import Foundation

/// A speech-to-text engine. Called from the main actor; implementations do
/// their work elsewhere (WhisperKitTranscriber is an actor).
///
/// Each engine takes what it can from `TranscriptionContext` and ignores the
/// rest: Whisper conditions on `prompt`; engines with a vocabulary input (for
/// example contextual strings in Apple Speech) take `vocabulary`. Every engine
/// gets the dictionary's replacement pass afterwards regardless.
protocol Transcriber: Sendable {
    var modelID: String { get }
    func transcribe(_ audio: [Float], context: TranscriptionContext) async throws -> Transcript
}

/// What the transcriber is told about the dictation beyond the audio.
/// Features fill these fields; engines use what they support.
package struct TranscriptionContext: Equatable, Sendable {
    /// Spoken language as an ISO 639-1 code, or nil to let the engine decide.
    var language: String?
    /// Natural text in `language` that biases the model toward expected
    /// words, such as the dictionary's example sentence, or nil for none.
    /// Never a bare list of terms: Whisper ignores a list (#23).
    package var prompt: String?
    /// Canonical spellings the user expects, for engines that take a word
    /// list. Empty for none. Whisper ignores it and uses `prompt`.
    var vocabulary: [String]

    init(language: String? = nil, prompt: String? = nil, vocabulary: [String] = []) {
        self.language = language
        self.prompt = prompt
        self.vocabulary = vocabulary
    }
}
