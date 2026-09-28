import CoreML
import Foundation
import WhisperKit

/// Where the Whisper models run and how they decode. `standard` is what the
/// app uses; `parrot-bench transcription` can run `baseline` or override the compute units
/// to compare them on another chip or model.
///
/// Each choice in `standard` was measured with `parrot-bench transcription` (#49); the
/// commit that set it has the numbers.
package struct WhisperTuning: Equatable, @unchecked Sendable {
    package var melCompute: MLComputeUnits = .cpuAndGPU
    package var encoderCompute: MLComputeUnits = .cpuAndNeuralEngine
    package var decoderCompute: MLComputeUnits = .cpuAndNeuralEngine
    /// Ask for text only when the audio fits one window. Dictation never
    /// uses segment timestamps.
    package var withoutTimestamps = false
    /// Cut leading and trailing silence before transcription.
    package var trimSilence = false
    /// Seconds of silence put before the audio after the trim, so speech
    /// never starts at the model's first sample (#53).
    package var leadPadding: Double = 0
    /// Seconds of silence put after the audio after the trim.
    package var trailPadding: Double = 0

    /// WhisperKit's defaults, as Parrot ran before #49.
    package static let baseline = WhisperTuning()

    package static let standard = WhisperTuning(
        melCompute: .cpuOnly,
        withoutTimestamps: true,
        trimSilence: true
    )

    /// The samples the model gets for a capture: trimmed if `trimSilence`,
    /// then padded with silence. An empty capture stays empty. Pure, so it is
    /// tested.
    func prepare(_ audio: [Float]) -> [Float] {
        let trimmed = trimSilence ? SilenceTrimmer.trim(audio) : audio
        guard !trimmed.isEmpty, leadPadding > 0 || trailPadding > 0 else { return trimmed }
        let lead = Self.samples(leadPadding)
        let trail = Self.samples(trailPadding)
        var out = [Float](repeating: 0, count: lead + trimmed.count + trail)
        out.replaceSubrange(lead..<(lead + trimmed.count), with: trimmed)
        return out
    }

    /// `seconds` of 16 kHz audio as a sample count; negative counts as none.
    static func samples(_ seconds: Double) -> Int {
        max(0, Int((seconds * Double(WhisperKit.sampleRate)).rounded()))
    }

    func decodingOptions(language: String?, promptTokens: [Int]?, audioSeconds: Double) -> DecodingOptions {
        var options = DecodingOptions()
        options.language = language
        options.promptTokens = promptTokens
        options.withoutTimestamps = withoutTimestamps && Self.fitsOneWindow(audioSeconds)
        return options
    }

    /// True when `seconds` of audio decode in a single 30 s window. Past that,
    /// WhisperKit needs segment timestamps to pick where the next window
    /// starts; without them it cuts at exactly 30 s, through a word.
    static func fitsOneWindow(_ seconds: Double) -> Bool {
        seconds <= Double(Constants.defaultWindowSamples) / Double(WhisperKit.sampleRate)
    }
}
