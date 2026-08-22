#if canImport(UIKit)
@preconcurrency import AVFoundation
import Foundation

/// Serializes the blocking AVAudioSession configuration calls away from the
/// main actor. AVFoundation documents `setActive` as synchronous and Xcode's
/// runtime checker reports a hang risk when it is invoked from the UI thread.
enum AudioSessionCoordinator {
    private static let queue = DispatchQueue(
        label: "com.denis.iTube.audio-session",
        qos: .userInitiated
    )

    static func activatePlayback() async throws {
        try await perform {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        }
    }

    static func deactivatePlayback() async throws {
        try await perform {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    private static func perform(
        _ operation: @escaping @Sendable () throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try operation()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
#endif
