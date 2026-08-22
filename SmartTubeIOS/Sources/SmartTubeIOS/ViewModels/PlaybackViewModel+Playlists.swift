import Foundation
import SmartTubeIOSCore

// MARK: - Player playlist actions

extension PlaybackViewModel {
    public func fetchPlaylistsForPicker() async throws -> [PlaylistInfo] {
        try await api.fetchUserPlaylists()
    }

    public func addCurrentVideo(to playlist: PlaylistInfo) async throws {
        guard let videoId = currentVideo?.id else { throw APIError.unavailable("No video is loaded") }
        try await api.addVideoToPlaylist(videoId: videoId, playlistId: playlist.id)
        toastMessage = String(localized: "Added to \(playlist.title)", bundle: .module)
    }

    public func createPlaylistAndAddCurrentVideo(title: String) async throws -> PlaylistInfo {
        let playlist = try await api.createPlaylist(title: title)
        try await addCurrentVideo(to: playlist)
        return playlist
    }
}
