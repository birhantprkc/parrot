import Foundation

/// Logs one line per delivered dictation: where the time went between the
/// hotkey release and the text reaching the cursor (#49). Timings and counts
/// only, never text.
@MainActor
final class LatencyLog: DictationObserver {
    private let write: (String) -> Void

    init(write: @escaping (String) -> Void = { Log.info($0) }) {
        self.write = write
    }

    func dictationFinished(_ result: DictationResult) {
        write(Self.line(for: result))
    }

    /// For example: `⏱ 412 ms release→text · 5.3 s audio ·
    /// press→first sample 142 ms · stop 3 · pre 4 ·
    /// enc 14 · dec 380 · post 1 · process 0 · deliver 2 ms · 17 tokens ·
    /// 1 window · 0 fallbacks`.
    static func line(for result: DictationResult) -> String {
        func ms(_ seconds: TimeInterval) -> String { String(format: "%.0f", seconds * 1000) }
        var parts = [
            "⏱ \(ms(result.releaseToText)) ms release→text",
            String(format: "%.1f s audio", result.captureDuration),
        ]
        // The other end of the dictation (#52): what the start of it lost.
        if let press = result.pressToFirstSample {
            parts.append("press→first sample \(ms(press)) ms")
        }
        parts.append("stop \(ms(result.captureStop))")
        if let t = result.transcriber {
            parts += [
                "pre \(ms(t.preprocessing))",
                "enc \(ms(t.encoder))",
                "dec \(ms(t.decoder))",
                "post \(ms(t.postprocessing))",
            ]
        } else {
            parts.append("transcribe \(ms(result.transcriptionTime))")
        }
        parts += [
            "process \(ms(result.processing))",
            "deliver \(ms(result.delivery)) ms",
        ]
        if let t = result.transcriber {
            if t.audioSeconds + 0.05 < result.captureDuration {
                parts.append(String(format: "trimmed to %.1f s", t.audioSeconds))
            }
            parts += [
                "\(t.tokens) tokens",
                "\(t.windows) window\(t.windows == 1 ? "" : "s")",
                "\(t.fallbacks) fallback\(t.fallbacks == 1 ? "" : "s")",
            ]
        }
        return parts.joined(separator: " · ")
    }
}
