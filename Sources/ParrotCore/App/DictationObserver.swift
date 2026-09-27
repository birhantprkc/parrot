import Foundation

/// Counts and timings for one delivered dictation. Never the text.
struct DictationResult: Equatable, Sendable {
    /// Seconds of audio captured.
    var captureDuration: TimeInterval
    /// Seconds the transcriber took.
    var transcriptionTime: TimeInterval
    /// Characters delivered, after every `TranscriptProcessor`.
    var charCount: Int
}

enum DictationError: Error {
    /// The hotkey was released with no audio captured.
    case noAudio
}

/// Follows the dictation loop: the overlay, the menu bar, and later stats.
///
/// `DictationController` calls these on the main actor, in the order the
/// observers were registered. Every method has an empty default, so an
/// observer implements only what it needs. New behaviour that reacts to a
/// dictation is an observer, not a branch in the controller.
@MainActor
protocol DictationObserver: AnyObject {
    /// Recording started.
    func dictationStarted()
    /// The hotkey was released; the capture is being transcribed.
    func dictationTranscribing()
    /// The transcript was delivered.
    func dictationFinished(_ result: DictationResult)
    /// Nothing was delivered: no audio (`DictationError.noAudio`) or the
    /// transcriber threw.
    func dictationFailed(_ error: Error)
}

extension DictationObserver {
    func dictationStarted() {}
    func dictationTranscribing() {}
    func dictationFinished(_ result: DictationResult) {}
    func dictationFailed(_ error: Error) {}
}
