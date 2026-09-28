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

    /// WhisperKit's defaults, as Parrot ran before #49.
    static let baseline = WhisperTuning()

    static let standard = baseline

    func decodingOptions(language: String?, promptTokens: [Int]?) -> DecodingOptions {
        var options = DecodingOptions()
        options.language = language
        options.promptTokens = promptTokens
        return options
    }
}
