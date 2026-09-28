import AVFoundation
import Foundation

/// Microphone authorization for the running daemon.
///
/// `Startup` exits on denied access before the daemon runs. This covers the
/// rest: asking once when the system has never asked, and refusing to start
/// the engine on a press when access is missing, so the user sees what to do
/// instead of a bare Core Audio error.
package enum MicrophoneAccess {
    package static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Shows the system prompt if the user has never answered it. Returns at
    /// once; the answer is logged, then `answered` runs on the main queue
    /// (at once if there was nothing to ask). Never blocks the main thread.
    package static func requestIfUndetermined(then answered: (@Sendable () -> Void)? = nil) {
        guard status == .notDetermined else {
            answered?()
            return
        }
        Log.info("requesting microphone access")
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Log.info(granted ? "microphone access granted" : CaptureError.microphoneDenied.userMessage)
            if let answered { DispatchQueue.main.async(execute: answered) }
        }
    }

    /// The error a press should fail with for `status`, or nil if capture may
    /// start.
    package static func captureError(for status: AVAuthorizationStatus) -> CaptureError? {
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
