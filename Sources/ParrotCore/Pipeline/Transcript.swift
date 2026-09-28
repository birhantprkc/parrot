/// The value that flows from the transcriber through each
/// `TranscriptProcessor` to delivery.
///
/// Holds the user's words. Never log it, write it to disk, or keep it after
/// delivery; observers get counts and timings (`DictationResult`) instead.
package struct Transcript: Equatable, Sendable {
    package var text: String
    /// Where the transcriber spent its time, when the engine reports it.
    /// Processors need not carry it on: the controller reads it from the
    /// transcriber's output.
    package var timings: TranscriberTimings?

    init(text: String, timings: TranscriberTimings? = nil) {
        self.text = text
        self.timings = timings
    }
}
