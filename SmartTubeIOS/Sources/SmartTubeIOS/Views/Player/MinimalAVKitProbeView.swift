#if os(tvOS)
import AVKit
import SwiftUI

/// Debug-only AVKit isolation probe. It deliberately contains no app menus,
/// delegates, gesture recognizers, focus routing, or custom metadata.
struct MinimalAVKitProbeView: UIViewControllerRepresentable {
    let player: AVPlayer
    let videoGravity: AVLayerVideoGravity

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = videoGravity
        controller.showsPlaybackControls = true
        controller.playbackControlsIncludeTransportBar = true
        controller.requiresLinearPlayback = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
        if controller.videoGravity != videoGravity {
            controller.videoGravity = videoGravity
        }
    }
}
#endif
