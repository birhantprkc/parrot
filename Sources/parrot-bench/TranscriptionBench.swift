import CoreML
import Foundation
import ParrotCore
import WhisperKit

/// Flags for `parrot-bench transcription`.
struct BenchOptions {
    /// Folder of recordings: `.wav` files, each optionally with a `.txt` of
    /// what was said beside it for the word error rate.
    var folder: String
    /// Timed runs per file.
    var runs: Int
    /// Model id; the recommended model when nil.
    var model: String?
    /// Prompt text instead of the dictionary's example sentence.
    var prompt: String?
    /// Run without any prompt, even if the dictionary has an example sentence.
    var noPrompt: Bool
    /// Run with WhisperKit's defaults, as Parrot ran before #49, to compare.
    var baseline: Bool
    /// Compute units for the audio encoder and text decoder: ane, gpu, cpu or
    /// all. Nil keeps the tuning's choice.
    var encoder: String?
    var decoder: String?
    /// Seconds to sit idle before each timed run, to see whether the first
    /// dictation after a pause is slower.
    var pause: Double

    init(
        folder: String,
        runs: Int = 10,
        model: String? = nil,
        prompt: String? = nil,
        noPrompt: Bool = false,
        baseline: Bool = false,
        encoder: String? = nil,
        decoder: String? = nil,
        pause: Double = 0
    ) {
        self.folder = folder
        self.runs = runs
        self.model = model
        self.prompt = prompt
        self.noPrompt = noPrompt
        self.baseline = baseline
        self.encoder = encoder
        self.decoder = decoder
        self.pause = pause
    }
}

/// `parrot-bench transcription <folder>`: runs the model over local recordings and prints
/// the median and p90 of each transcription stage, per file. Capture stop and
/// delivery need the microphone and a focused app, so they are only in the
/// daemon's per-dictation log line.
///
/// Prints timings, counts and word error rates, never transcript text.
enum TranscriptionBench {
    static func run(_ options: BenchOptions) throws {
        guard options.runs > 0 else {
            print("--runs must be at least 1")
            throw SilentExit(64)
        }
        guard let model = options.model.map(ModelRegistry.find) ?? ModelRegistry.recommended() else {
            print("unknown model: \(options.model ?? "")")
            throw SilentExit(1)
        }
        guard WhisperKitTranscriber.isCached(model) else {
            print("\(model.id) is not downloaded; run: parrot models download \(model.id)")
            throw SilentExit(1)
        }
        var tuning = options.baseline ? WhisperTuning.baseline : WhisperTuning.standard
        if let name = options.encoder {
            guard let units = computeUnits(name) else {
                print("--encoder: expected ane, gpu, cpu or all")
                throw SilentExit(64)
            }
            tuning.encoderCompute = units
        }
        if let name = options.decoder {
            guard let units = computeUnits(name) else {
                print("--decoder: expected ane, gpu, cpu or all")
                throw SilentExit(64)
            }
            tuning.decoderCompute = units
        }

        let files = try recordings(in: options.folder)
        guard !files.isEmpty else {
            print("no .wav files in \(options.folder)")
            throw SilentExit(1)
        }

        let language = DictionaryContext.knownLanguage(of: model)
        var chosen = DictionaryContext(store: DictionaryStore(), language: language).context()
        if options.noPrompt { chosen.prompt = nil }
        if let prompt = options.prompt { chosen.prompt = prompt }
        let context = chosen
        let promptLabel = context.prompt.map { "\($0.split(separator: " ").count) words" } ?? "none"

        let transcriber = WhisperKitTranscriber(model: model, tuning: tuning)
        try blocking { try await transcriber.warmUp() }

        print("model \(model.id) · \(options.baseline ? "baseline" : "standard") tuning · \(describe(tuning)) · prompt \(promptLabel)")
        print("\(files.count) files · \(options.runs) runs each\(options.pause > 0 ? String(format: " · %.0f s idle before each", options.pause) : "") · ms, median/p90")

        // The first transcription after loading pays for CoreML's first
        // prediction; report it and keep it out of the medians.
        let firstAudio = try AudioProcessor.loadAudioAsFloatArray(fromPath: files[0].audio.path)
        let first = try blocking { try await transcriber.transcribe(firstAudio, context: context) }
        print(String(format: "first transcription after load: %.0f ms", (first.timings?.total ?? 0) * 1000))
        print("")
        print(Row.header)

        var totalErrors = 0
        var totalWords = 0
        for file in files {
            let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: file.audio.path)
            var samples: [TranscriberTimings] = []
            var wer: WordErrorRate?
            for _ in 0..<options.runs {
                if options.pause > 0 { Thread.sleep(forTimeInterval: options.pause) }
                let transcript = try blocking { try await transcriber.transcribe(audio, context: context) }
                samples.append(transcript.timings ?? TranscriberTimings.zero)
                if wer == nil, let reference = file.reference {
                    wer = WordErrorRate(reference: reference, hypothesis: transcript.text)
                }
            }
            if let wer {
                totalErrors += wer.errors
                totalWords += wer.referenceWords
            }
            print(Row(name: file.audio.lastPathComponent, audioSeconds: Double(audio.count) / 16_000, samples: samples, wer: wer).text)
        }
        if totalWords > 0 {
            print(String(format: "\nWER %.1f%% (%d errors / %d words)", 100 * Double(totalErrors) / Double(totalWords), totalErrors, totalWords))
        }
    }

    struct Recording {
        var audio: URL
        /// What was said, from `<name>.txt` beside the audio.
        var reference: String?
    }

    static func recordings(in folder: String) throws -> [Recording] {
        let dir = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        return names
            .filter { $0.lowercased().hasSuffix(".wav") }
            .sorted()
            .map { name in
                let audio = dir.appendingPathComponent(name)
                let text = audio.deletingPathExtension().appendingPathExtension("txt")
                return Recording(audio: audio, reference: try? String(contentsOf: text, encoding: .utf8))
            }
    }

    /// One printed line: a file's stages over its runs.
    struct Row {
        static let header = "file                     audio  total      pre      enc      dec        post    tokens  win  fb   WER"

        var name: String
        var audioSeconds: Double
        var samples: [TranscriberTimings]
        var wer: WordErrorRate?

        var text: String {
            func stage(_ key: KeyPath<TranscriberTimings, TimeInterval>) -> String {
                let values = samples.map { $0[keyPath: key] * 1000 }
                return String(format: "%.0f/%.0f", Percentile.of(values, 50), Percentile.of(values, 90))
            }
            let tokens = Percentile.of(samples.map { Double($0.tokens) }, 50)
            let windows = Percentile.of(samples.map { Double($0.windows) }, 50)
            let fallbacks = samples.map(\.fallbacks).reduce(0, +)
            let werText = wer.map { String(format: "%5.1f%%", $0.rate * 100) } ?? "     -"
            return name.padding(toLength: 24, withPad: " ", startingAt: 0)
                + String(format: "%5.1fs", audioSeconds)
                + "  " + stage(\.total).padding(toLength: 11, withPad: " ", startingAt: 0)
                + stage(\.preprocessing).padding(toLength: 9, withPad: " ", startingAt: 0)
                + stage(\.encoder).padding(toLength: 9, withPad: " ", startingAt: 0)
                + stage(\.decoder).padding(toLength: 11, withPad: " ", startingAt: 0)
                + stage(\.postprocessing).padding(toLength: 8, withPad: " ", startingAt: 0)
                + String(format: "%6.0f %4.0f %3d  ", tokens, windows, fallbacks)
                + werText
        }
    }

    static func describe(_ tuning: WhisperTuning) -> String {
        var parts = [
            "mel \(label(tuning.melCompute))",
            "encoder \(label(tuning.encoderCompute))",
            "decoder \(label(tuning.decoderCompute))",
        ]
        if tuning.withoutTimestamps { parts.append("no timestamps") }
        if tuning.trimSilence { parts.append("trim") }
        return parts.joined(separator: " · ")
    }

    static func computeUnits(_ name: String) -> MLComputeUnits? {
        switch name {
        case "ane": return .cpuAndNeuralEngine
        case "gpu": return .cpuAndGPU
        case "cpu": return .cpuOnly
        case "all": return .all
        default: return nil
        }
    }

    static func label(_ units: MLComputeUnits) -> String {
        switch units {
        case .cpuAndNeuralEngine: return "ane"
        case .cpuAndGPU: return "gpu"
        case .cpuOnly: return "cpu"
        case .all: return "all"
        @unknown default: return "?"
        }
    }

    /// Runs `body` to completion from synchronous command code.
    private static func blocking<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>?
        Task.detached {
            do { result = .success(try await body()) } catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result!.get()
    }
}

/// Nearest-rank percentile. Pure, so it is tested.
enum Percentile {
    /// The `p`th percentile of `values` (0 < p ≤ 100), or 0 when empty.
    static func of(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

/// Word error rate between what was said and what was transcribed: word-level
/// edit distance over the reference's word count, after lowercasing and
/// dropping punctuation. Pure, so it is tested.
struct WordErrorRate: Equatable {
    /// Substitutions, deletions and insertions.
    var errors: Int
    var referenceWords: Int

    var rate: Double { referenceWords == 0 ? (errors == 0 ? 0 : 1) : Double(errors) / Double(referenceWords) }

    init(reference: String, hypothesis: String) {
        let ref = Self.words(reference)
        let hyp = Self.words(hypothesis)
        referenceWords = ref.count
        errors = Self.editDistance(ref, hyp)
    }

    /// Lowercased words with punctuation removed; apostrophes inside a word
    /// stay, and hyphens split words.
    static func words(_ text: String) -> [String] {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        var cleaned = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber || ch == "'" { cleaned.append(ch) } else { cleaned.append(" ") }
        }
        return cleaned
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
