import Foundation

/// The dictation loop: gesture → capture → transcribe → process → deliver.
///
/// Owns the state machine and nothing else. Features plug in as a
/// `TranscriptProcessor` (after transcription, before delivery) or a
/// `DictationObserver` (reacting to the loop), not as branches here.
///
/// Edge cases, kept exactly as the loop behaved before this type existed:
/// - A press always tries to start capture, even while an earlier capture is
///   still transcribing. That transcription still delivers, and its
///   `dictationFinished` reaches observers while the new recording runs.
/// - A press whose capture fails to start logs and notifies `dictationFailed`
///   with the capture error; the state does not change.
/// - A release always stops capture and notifies `dictationTranscribing`,
///   even with nothing recorded; an empty capture then fails with
///   `DictationError.noAudio`.
/// - A transcript that does not reach the cursor (a secure field, or focus
///   moved since the press) fails with its `DeliveryError`.
@MainActor
final class DictationController {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
    }

    private(set) var state: State = .idle

    private let capture: AudioCapture
    private let transcriber: Transcriber
    private let processors: [TranscriptProcessor]
    private let observers: [DictationObserver]
    private let dumpWav: Bool
    private let delivery: TextDelivery
    /// Transcriptions started and not yet finished or failed.
    private var inFlight = 0
    /// What had focus when the current recording started (#38).
    private var focusAtStart: FocusSnapshot?

    init(
        capture: AudioCapture,
        transcriber: Transcriber,
        processors: [TranscriptProcessor] = [],
        observers: [DictationObserver],
        dumpWav: Bool = false,
        delivery: TextDelivery
    ) {
        self.capture = capture
        self.transcriber = transcriber
        self.processors = processors
        self.observers = observers
        self.dumpWav = dumpWav
        self.delivery = delivery
    }

    func handle(_ event: HotkeyMonitor.Event) {
        switch event {
        case .pressed: press()
        case .released: release()
        }
    }

    func press() {
        do {
            try capture.start()
        } catch {
            Log.error("capture failed: \(error)")
            observers.forEach { $0.dictationFailed(error) }
            return
        }
        focusAtStart = FocusSnapshot.capture()
        Log.info("● recording")
        state = .recording
        observers.forEach { $0.dictationStarted() }
    }

    func release() {
        let samples = capture.stop()
        let focus = focusAtStart
        focusAtStart = nil
        state = .transcribing
        observers.forEach { $0.dictationTranscribing() }

        let seconds = Double(samples.count) / AudioCapture.targetSampleRate
        Log.info(String(format: "○ captured %.2fs · rms %.3f", seconds, computeRMS(samples)))
        if dumpWav, !samples.isEmpty {
            writeDump(samples)
        }

        guard !samples.isEmpty else {
            settle()
            observers.forEach { $0.dictationFailed(DictationError.noAudio) }
            return
        }

        inFlight += 1
        let transcriber = self.transcriber
        let context = TranscriptionContext()
        Task {
            let started = Date()
            do {
                // The transcriber is an actor; this await runs off the main actor.
                let raw = try await transcriber.transcribe(samples, context: context)
                let elapsed = Date().timeIntervalSince(started)
                // Never log the transcript itself: the agent's log is a file on disk.
                Log.info(String(format: "→ %.2fs · %d chars", elapsed, raw.text.count))
                let transcript = processors.reduce(raw) { $1.process($0) }
                let delivered = Result { try delivery.deliver(transcript.text, focusAtStart: focus) }
                inFlight -= 1
                settle()
                if case .failure(let error) = delivered {
                    observers.forEach { $0.dictationFailed(error) }
                    return
                }
                let result = DictationResult(
                    captureDuration: seconds,
                    transcriptionTime: elapsed,
                    charCount: transcript.text.count
                )
                observers.forEach { $0.dictationFinished(result) }
            } catch {
                Log.error("transcription failed: \(error)")
                inFlight -= 1
                settle()
                observers.forEach { $0.dictationFailed(error) }
            }
        }
    }

    /// After a transcription ends, return to idle unless a newer recording
    /// or transcription is still running.
    private func settle() {
        if state == .transcribing, inFlight == 0 {
            state = .idle
        }
    }

    private func writeDump(_ samples: [Float]) {
        do {
            try Paths.prepareDirectory(Paths.caches)
            let path = try Paths.preparePrivateFile(Paths.dumpWav).path
            try WAVWriter.write(samples: samples, sampleRate: 16_000, to: path)
            Log.info("  wrote \(path)")
        } catch {
            Log.error("  wav write failed: \(error)")
        }
    }
}
