import CoreML
import Foundation
import WhisperKit

/// Whisper's language detection, choosing only among the user's languages.
///
/// The steps are WhisperKit's `detectLangauge` (the first 30 s of audio, the
/// mel spectrogram, the encoder, then one decoder step after
/// `<|startoftranscript|>`), with one difference: WhisperKit lets every
/// language token compete and takes the top one, while this reads only the
/// scores of `languages` and shares the probability among them. With English
/// and Spanish, a Spanish clip can never come back as Italian or Portuguese,
/// which Whisper confuses it with on short clips, and a wrong language comes
/// back as a translation.
enum LanguageDetector {
    enum DetectionError: Error {
        case unavailable(String)
    }

    /// The most likely of `languages` in `audio`, with each language's
    /// probability, highest first. `languages` must be codes the model knows.
    static func detect(
        _ audio: [Float],
        among languages: [String],
        pipeline: WhisperKit
    ) async throws -> [(code: String, probability: Float)] {
        guard let tokenizer = pipeline.tokenizer else { throw DetectionError.unavailable("no tokenizer") }
        let decoder = pipeline.textDecoder

        guard let samples = pipeline.audioProcessor.padOrTrim(
            fromArray: audio,
            startAt: 0,
            toLength: pipeline.featureExtractor.windowSamples ?? Constants.defaultWindowSamples
        ) else { throw DetectionError.unavailable("no audio") }
        guard let mel = try await pipeline.featureExtractor.logMelSpectrogram(fromAudio: samples),
              let encoded = try await pipeline.audioEncoder.encodeFeatures(mel) as? MLMultiArray
        else { throw DetectionError.unavailable("encoder produced nothing") }

        let start = tokenizer.specialTokens.startOfTranscriptToken
        guard let inputs = try decoder.prepareDecoderInputs(withPrompt: [start]) as? DecodingInputs else {
            throw DetectionError.unavailable("unexpected decoder inputs")
        }
        inputs.inputIds[0] = NSNumber(value: start)
        inputs.cacheLength[0] = NSNumber(value: 0)
        let output = try await decoder.predictLogits(TextDecoderMLMultiArrayInputType(
            inputIds: inputs.inputIds,
            cacheLength: inputs.cacheLength,
            keyCache: inputs.keyCache,
            valueCache: inputs.valueCache,
            kvCacheUpdateMask: inputs.kvCacheUpdateMask,
            encoderOutputEmbeds: encoded,
            decoderKeyPaddingMask: inputs.decoderKeyPaddingMask
        )) as? TextDecoderMLMultiArrayOutputType
        guard let logits = output?.logits else { throw DetectionError.unavailable("decoder produced nothing") }

        // Each language's score is the logit of its token, <|es|> for "es".
        let scores: [(String, Float)] = languages.compactMap { code in
            guard let token = tokenizer.convertTokenToId("<|\(code)|>") else { return nil }
            return (code, logits[[0, 0, NSNumber(value: token)]].floatValue)
        }
        guard !scores.isEmpty else { throw DetectionError.unavailable("no language tokens") }
        return SpokenLanguage.probabilities(scores)
    }
}
