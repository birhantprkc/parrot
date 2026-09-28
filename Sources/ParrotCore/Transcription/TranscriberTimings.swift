import Foundation

/// Where one transcription spent its time, as the engine reports it. Seconds,
/// and counts; never text.
///
/// The stages add up to `total`: whatever the engine does not attribute to
/// preprocessing, the encoder or the decoder is `postprocessing`.
struct TranscriberTimings: Equatable, Sendable {
    /// Seconds of audio handed to the model, after any trimming.
    var audioSeconds: TimeInterval = 0
    /// Silence trimming, padding the window, and the log-mel spectrogram.
    var preprocessing: TimeInterval = 0
    /// The audio encoder, over every 30 s window.
    var encoder: TimeInterval = 0
    /// Decoder setup, the prompt, the token loop, and any temperature fallbacks.
    var decoder: TimeInterval = 0
    /// Segmenting, detokenizing and cleaning up the text.
    var postprocessing: TimeInterval = 0
    /// The whole `transcribe` call, wall clock.
    var total: TimeInterval = 0
    /// 30 s windows encoded.
    var windows = 0
    /// Decoder steps, prompt included.
    var tokens = 0
    /// Temperature fallbacks: decodes thrown away and retried.
    var fallbacks = 0
}
