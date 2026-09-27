import Foundation

protocol Transcriber {
    var modelID: String { get }
    func transcribe(_ audio: [Float], context: TranscriptionContext) async throws -> Transcript
}

/// What the transcriber is told about the dictation beyond the audio.
/// Features fill these fields; engines use what they support.
struct TranscriptionContext: Equatable, Sendable {
    /// Spoken language as an ISO 639-1 code, or nil to let the engine decide.
    var language: String?
    /// Text that biases the model toward expected words (for example the
    /// user's dictionary terms), or nil for none.
    var prompt: String?

    init(language: String? = nil, prompt: String? = nil) {
        self.language = language
        self.prompt = prompt
    }
}
