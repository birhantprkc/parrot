import Foundation

/// Cuts leading and trailing silence from a 16 kHz capture with a simple
/// energy threshold. Pure, so it is tested.
///
/// A push-to-talk capture starts before the first word and ends after the
/// last. Whisper pads every window to 30 s, so trimming does not shorten the
/// encoder's work within a window; it matters where the silence pushes a
/// capture past 30 s into a second window, and on quiet tails, where Whisper
/// can hallucinate text.
///
/// It errs toward keeping audio: a margin stays on each side, and a capture
/// whose loudest frame never clears the threshold comes back unchanged.
enum SilenceTrimmer {
    static let sampleRate = 16_000
    /// 10 ms frames.
    static let frameLength = 160
    /// Frames quieter than this RMS are silence whatever the rest of the capture.
    static let minimumLevel: Float = 0.003
    /// Frames quieter than this fraction of the loudest frame's RMS (−26 dB) are silence.
    static let relativeLevel: Float = 0.05
    /// Audio kept before the first voiced frame, for soft onsets.
    static let leadMargin = 0.25
    /// Audio kept after the last voiced frame, for trailing consonants.
    static let trailMargin = 0.35

    /// `audio` without its leading and trailing silence, margins kept.
    static func trim(_ audio: [Float]) -> [Float] {
        guard let range = voicedRange(audio) else { return audio }
        if range.count == audio.count { return audio }
        return Array(audio[range])
    }

    /// The sample range to keep, or nil if nothing clears the threshold.
    static func voicedRange(_ audio: [Float]) -> Range<Int>? {
        let frames = audio.count / frameLength
        guard frames > 0 else { return nil }
        var levels = [Float](repeating: 0, count: frames)
        audio.withUnsafeBufferPointer { samples in
            for f in 0..<frames {
                var sum: Float = 0
                for s in samples[(f * frameLength)..<((f + 1) * frameLength)] { sum += s * s }
                levels[f] = (sum / Float(frameLength)).squareRoot()
            }
        }
        let peak = levels.max() ?? 0
        let threshold = max(minimumLevel, peak * relativeLevel)
        guard peak >= threshold,
              let first = levels.firstIndex(where: { $0 >= threshold }),
              let last = levels.lastIndex(where: { $0 >= threshold })
        else { return nil }
        let start = max(0, first * frameLength - Int(leadMargin * Double(sampleRate)))
        let end = min(audio.count, (last + 1) * frameLength + Int(trailMargin * Double(sampleRate)))
        return start..<end
    }
}
