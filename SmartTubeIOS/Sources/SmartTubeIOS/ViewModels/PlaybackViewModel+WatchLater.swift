import Foundation
import SmartTubeIOSCore

// MARK: - Watch Later

extension PlaybackViewModel {

    /// Adds or removes the current video from the user's real YouTube Watch Later
    /// playlist. The control updates immediately and rolls back if the request fails.
    public func toggleWatchLater() {
        guard let videoId = currentVideo?.id, !isUpdatingWatchLater else { return }

        let previousValue = isInWatchLater
        isInWatchLater.toggle()
        isUpdatingWatchLater = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if previousValue {
                    try await api.removeFromWatchLater(videoId: videoId)
                    toastMessage = String(localized: "Removed from Watch Later", bundle: .module)
                } else {
                    try await api.addToWatchLater(videoId: videoId)
                    toastMessage = String(localized: "Saved to Watch Later", bundle: .module)
                }
            } catch {
                isInWatchLater = previousValue
                toastMessage = error.localizedDescription
            }
            isUpdatingWatchLater = false
        }
    }
}
