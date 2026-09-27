import AVFoundation
import Foundation

/// Microphone authorization for the running daemon.
///
/// `Startup` exits on denied access before the daemon runs. This covers the
/// rest: asking once when the system has never asked, and refusing to start
/// the engine on a press when access is missing, so the user sees what to do
/// instead of a bare Core Audio error.
enum MicrophoneAccess {
    static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Shows the system prompt if the user has never answered it. Returns at
    /// once; the answer is only logged. Never blocks the main thread.
    static func requestIfUndetermined() {
        guard status == .notDetermined else { return }
        Log.info("requesting microphone access")
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Log.info(granted ? "microphone access granted" : CaptureError.microphoneDenied.userMessage)
        }
    }

    /// The error a press should fail with for `status`, or nil if capture may
    /// start.
    static func captureError(for status: AVAuthorizationStatus) -> CaptureError? {
        switch status {
        case .authorized:
            return nil
        case .denied, .restricted:
            return .microphoneDenied
        case .notDetermined:
            return .microphonePending
        @unknown default:
            return nil
        }
    }
}
