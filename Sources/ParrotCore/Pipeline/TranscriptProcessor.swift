/// One post-transcription step, such as the dictionary's replacement pass.
///
/// `DictationController` runs its processors in order between the
/// transcriber and delivery. Synchronous, and pure where possible, so each
/// step can be unit tested on its own. New behaviour after transcription is a
/// processor, not a branch in the controller.
protocol TranscriptProcessor {
    func process(_ transcript: Transcript) -> Transcript
}
