import Foundation
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    private var pipeline: WhisperKit?

    init(model: TranscriptionModel) {
        self.modelID = model.id
        self.model = model
    }

    /// Loads the model into memory; downloads first if not already on disk.
    /// Call once at startup so the first hotkey press isn't blocked on model
    /// download/load.
    func warmUp() async throws {
        if pipeline != nil { return }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        Log.info("loading \(model.id)...")
        // Explicit downloadBase: the HubApi default is ~/Documents/huggingface,
        // which the launchd daemon can't read and iCloud may evict. The
        // tokenizer folder follows downloadBase.
        let base = try Paths.prepareDirectory(Paths.appSupport)
        let config = WhisperKitConfig(
            model: whisperKitID,
            downloadBase: base,
            verbose: false,
            prewarm: true,
            load: true
        )
        pipeline = try await WhisperKit(config)
        Log.info("✓ \(model.id) ready")
    }

    /// `context` is not used yet: language and prompt support arrive with
    /// their features.
    func transcribe(_ audio: [Float], context: TranscriptionContext) async throws -> Transcript {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        let results = try await pipeline.transcribe(audioArray: audio)
        let raw = results.map(\.text).joined(separator: " ")
        return Transcript(text: Self.sanitize(raw))
    }

    /// Strip Whisper's non-speech bracket tokens ([BLANK_AUDIO], [MUSIC],
    /// (silence), <|nospeech|>, etc.) and collapse whitespace. When the model
    /// hears silence it emits these literally; we don't want to paste them.
    static func sanitize(_ text: String) -> String {
        let patterns = [
            #"\[[^\]]*\]"#,        // [BLANK_AUDIO], [MUSIC], [Applause]
            #"\([^)]*\)"#,          // (silence), (music playing)
            #"<\|[^|]*\|>"#,        // <|nospeech|>, <|endoftext|>
            #"\*[^*]*\*"#,          // *background noise*
        ]
        var out = text
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - On-disk cache

extension WhisperKitTranscriber {
    /// True if `model`'s weights are already under `Paths.appSupport`.
    static func isCached(_ model: TranscriptionModel) -> Bool {
        guard let variant = model.whisperKitID else { return false }
        let dir = Paths.appSupport.appendingPathComponent(folders(for: variant)[0])
        return FileManager.default.fileExists(atPath: dir.path)
    }

    /// True if any registry model is still in the pre-0.0.6 ~/Documents cache.
    /// Reads ~/Documents, so foreground commands only.
    static func hasLegacyModels() -> Bool {
        ModelRegistry.shared.contains { m in
            guard let variant = m.whisperKitID else { return false }
            return FileManager.default.fileExists(atPath: Paths.legacyModels.appendingPathComponent(folders(for: variant)[0]).path)
        }
    }

    /// Move models that parrot ≤0.0.5 downloaded into ~/Documents/huggingface
    /// to `Paths.appSupport`, so they aren't downloaded again. Only moves the
    /// registry's own folders; other apps share that directory. Reads
    /// ~/Documents, so call it from foreground commands only, never the daemon.
    static func migrateLegacyModels() {
        let fm = FileManager.default
        let old = Paths.legacyModels
        guard fm.fileExists(atPath: old.path) else { return }
        let new: URL
        do {
            new = try Paths.prepareDirectory(Paths.appSupport)
        } catch {
            Log.warning("model migration skipped: \(error)")
            return
        }

        for model in ModelRegistry.shared {
            guard let variant = model.whisperKitID else { continue }
            let folders = folders(for: variant)
            guard fm.fileExists(atPath: old.appendingPathComponent(folders[0]).path) else { continue }
            if fm.fileExists(atPath: new.appendingPathComponent(folders[0]).path) {
                print("  \(model.id): already in \(new.path); the old copy in \(old.path) can be deleted")
                continue
            }
            // Moving an iCloud-evicted file would block on materializing it.
            // Leave it and let WhisperKit download a fresh copy instead.
            let sources = folders.map { old.appendingPathComponent($0) }
            if sources.contains(where: containsDataless) {
                print("  \(model.id): evicted by iCloud, will download again instead of moving")
                continue
            }
            do {
                for folder in folders {
                    let src = old.appendingPathComponent(folder)
                    let dst = new.appendingPathComponent(folder)
                    guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: src, to: dst)
                }
                print("✓ moved \(model.id) to \(new.path)")
            } catch {
                Log.warning("couldn't move \(model.id): \(error)")
            }
        }

        // Prune the now-empty folders parrot created, deepest first. Anything
        // with other contents stays.
        for sub in [
            "models/argmaxinc/whisperkit-coreml/.cache/huggingface/download",
            "models/argmaxinc/whisperkit-coreml/.cache/huggingface",
            "models/argmaxinc/whisperkit-coreml/.cache",
            "models/argmaxinc/whisperkit-coreml",
            "models/argmaxinc",
            "models/openai",
            "models",
            "",
        ] {
            removeIfEmpty(old.appendingPathComponent(sub))
        }
    }

    /// Hub-relative folders WhisperKit writes for `variant`: the weights, their
    /// download metadata, and the tokenizer. The weights folder comes first.
    private static func folders(for variant: String) -> [String] {
        let repo = "models/argmaxinc/whisperkit-coreml"
        return [
            "\(repo)/\(variant)",
            "\(repo)/.cache/huggingface/download/\(variant)",
            "models/openai/\(tokenizerName(for: variant))",
        ]
    }

    /// Mirrors WhisperKit's tokenizer choice for the registry's variants:
    /// "openai_whisper-base.en" → "whisper-base.en"; every large-v3 build,
    /// including turbo, uses "whisper-large-v3".
    private static func tokenizerName(for variant: String) -> String {
        let name = variant.replacingOccurrences(of: "openai_", with: "")
        return name.hasPrefix("whisper-large-v3") ? "whisper-large-v3" : name
    }

    /// True if `url` or anything under it is an iCloud dataless placeholder.
    /// Checks flags with lstat, which never triggers a download.
    private static func containsDataless(_ url: URL) -> Bool {
        func isDataless(_ path: String) -> Bool {
            var st = stat()
            return lstat(path, &st) == 0 && st.st_flags & UInt32(SF_DATALESS) != 0
        }
        if isDataless(url.path) { return true }
        guard let walker = FileManager.default.enumerator(atPath: url.path) else { return false }
        while let rel = walker.nextObject() as? String {
            if isDataless(url.appendingPathComponent(rel).path) { return true }
        }
        return false
    }

    private static func removeIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path),
              items.allSatisfy({ $0 == ".DS_Store" })
        else { return }
        try? fm.removeItem(at: dir)
    }
}

enum TranscriberError: Error {
    case missingEngineID
    case notLoaded
}
