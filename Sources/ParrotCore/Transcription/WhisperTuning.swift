import CoreML
import Foundation
import WhisperKit

/// Where the Whisper models run and how they decode. `standard` is what the
/// app uses; `parrot bench` can run `baseline` or override the compute units
/// to compare them on another chip or model.
///
/// Each choice in `standard` was measured with `parrot bench` (#49); the
/// commit that set it has the numbers.
struct WhisperTuning: Equatable, @unchecked Sendable {
    var melCompute: MLComputeUnits = .cpuAndGPU
    var encoderCompute: MLComputeUnits = .cpuAndNeuralEngine
    var decoderCompute: MLComputeUnits = .cpuAndNeuralEngine
    /// Ask for text only when the audio fits one window. Dictation never
    /// uses segment timestamps.
    var withoutTimestamps = false

    /// WhisperKit's defaults, as Parrot ran before #49.
    static let baseline = WhisperTuning()

    static let standard = WhisperTuning(
        withoutTimestamps: true
    )

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
