import Foundation

/// Where one transcription spent its time, as the engine reports it. Seconds,
/// and counts; never text.
///
/// The stages add up to `total`: whatever the engine does not attribute to
/// preprocessing, the encoder or the decoder is `postprocessing`.
package struct TranscriberTimings: Equatable, Sendable {
    /// No time spent, for a transcription the engine did not time.
    package static let zero = TranscriberTimings()

    /// Seconds of audio handed to the model, after any trimming.
    var audioSeconds: TimeInterval = 0
    /// Silence trimming, padding the window, and the log-mel spectrogram.
    package var preprocessing: TimeInterval = 0
    /// The audio encoder, over every 30 s window.
    package var encoder: TimeInterval = 0
    /// Decoder setup, the prompt, the token loop, and any temperature fallbacks.
    package var decoder: TimeInterval = 0
    /// Segmenting, detokenizing and cleaning up the text.
    package var postprocessing: TimeInterval = 0
    /// The whole `transcribe` call, wall clock.
    package var total: TimeInterval = 0
    /// 30 s windows encoded.
    package var windows = 0
    /// Decoder steps, prompt included.
    package var tokens = 0
    /// Temperature fallbacks: decodes thrown away and retried.
    package var fallbacks = 0
}
