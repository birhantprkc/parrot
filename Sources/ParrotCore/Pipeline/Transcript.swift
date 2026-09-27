/// The value that flows from the transcriber through each
/// `TranscriptProcessor` to delivery.
///
/// Holds the user's words. Never log it, write it to disk, or keep it after
/// delivery; observers get counts and timings (`DictationResult`) instead.
struct Transcript: Equatable, Sendable {
    var text: String
}
