import Foundation
import Observation
import os

private let playlistLog = ViewModelLogger(category: "Playlist")

// MARK: - QueuedPlaylistLoader
//
// Seam that decouples PlaylistViewModel from CurrentQueueStore's concrete type.
// The default adapter (`CurrentQueuePlaylistLoader`) delegates to the store;
// tests inject a mock that returns controlled video arrays.

public protocol QueuedPlaylistLoader: Sendable {
    /// Returns the current play-queue videos tagged with playlist metadata,
    /// or `nil` if the given playlist ID is not the play queue.
    func loadQueuedVideos(for playlistId: String) async -> [Video]?
}

public struct CurrentQueuePlaylistLoader: QueuedPlaylistLoader {
    public init() {}
    public func loadQueuedVideos(for playlistId: String) async -> [Video]? {
        guard playlistId == CurrentQueueStore.playlistID else { return nil }
        let videos = await CurrentQueueStore.shared.videos
        return videos.enumerated().map { index, v in
            var copy           = v
            copy.playlistId    = CurrentQueueStore.playlistID
            copy.playlistIndex = index
            return copy
        }
    }
}

// MARK: - PlaylistViewModel
//
// Fetches and paginates the videos inside a single playlist.
// Mirrors the Android `PlaylistPresenter`.

@MainActor
@Observable
public final class PlaylistViewModel {
    public private(set) var videos: [Video] = []
    public private(set) var isLoading = false
    public var error: Error?

    private var playlistId: String = ""
    private var nextPageToken: String?
    private var fetchTask: Task<Void, Never>?
    private let api: any InnerTubeAPIProtocol
    private let queueLoader: any QueuedPlaylistLoader
    private var hideObserverTokens: [NSObjectProtocol] = []

    public init(
        api: any InnerTubeAPIProtocol = InnerTubeAPI(),
        queueLoader: any QueuedPlaylistLoader = CurrentQueuePlaylistLoader()
    ) {
        self.api = api
        self.queueLoader = queueLoader
        observeFeedHideNotifications()
    }

    isolated deinit {
        for token in hideObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    public func load(playlistId: String, refresh: Bool = false) {
        // ── Queue short-circuit ────────────────────────────────────────────────
        // Delegates to `queueLoader` so this ViewModel is not coupled to
        // CurrentQueueStore's concrete type or magic playlist ID.
        fetchTask?.cancel()
        fetchTask = Task {
            if let queuedVideos = await self.queueLoader.loadQueuedVideos(for: playlistId) {
                self.videos = queuedVideos
                return
            }
            // ── Existing API path ──────────────────────────────────────────────────
            // If the same playlist is already loaded and no refresh was requested,
            // do nothing — this preserves scroll position when navigating back.
            if !refresh && self.playlistId == playlistId && !self.videos.isEmpty {
                return
            }
            if refresh || self.playlistId != playlistId {
                self.playlistId = playlistId
                self.videos = []
                self.nextPageToken = nil
            }
            await self.fetch()
        }
    }

    public func loadMoreIfNeeded(lastVideo: Video) {
        guard let last = videos.last, last.id == lastVideo.id,
              nextPageToken != nil, !isLoading else { return }
        fetchTask = Task { await fetch() }
    }

    private func fetch() async {
        isLoading = true
        defer { isLoading = false }
        playlistLog.notice("fetchPlaylistVideos page=\(self.nextPageToken == nil ? "first" : "continuation")")
        do {
            let group = try await retryWithBackoff(label: "PlaylistVM") {
                try await api.fetchPlaylistVideos(playlistId: self.playlistId, continuationToken: self.nextPageToken)
            }
            if !Task.isCancelled {
                // Tag each video with the playlistId and its position so the player
                // can navigate next/prev in the correct order. The offset accounts for
                // previously-loaded pages so indices are monotonically increasing.
                let offset = videos.count
                let tagged = group.videos.enumerated().map { (idx, v) -> Video in
                    var copy = v
                    copy.playlistId = playlistId
                    copy.playlistIndex = offset + idx
                    return copy
                }
                videos.append(contentsOf: tagged)
                nextPageToken = group.nextPageToken
                playlistLog.notice("fetchPlaylistVideos → \(tagged.count) videos (total \(self.videos.count))")
            }
        } catch {
            if !Task.isCancelled {
                playlistLog.error("fetchPlaylistVideos error: \(String(describing: error))")
                self.error = error
            }
        }
    }

    // MARK: - Feed hide handling

    private func observeFeedHideNotifications() {
        let center = NotificationCenter.default
        hideObserverTokens.append(center.addObserver(forName: .hideVideoFromFeed, object: nil, queue: .main) { [weak self] note in
            guard let videoId = note.userInfo?["videoId"] as? String else { return }
            Task { @MainActor [weak self] in self?.videos.removeAll { $0.id == videoId } }
        })
        hideObserverTokens.append(center.addObserver(forName: .hideChannelFromFeed, object: nil, queue: .main) { [weak self] note in
            guard let channelId = note.userInfo?["channelId"] as? String else { return }
            Task { @MainActor [weak self] in self?.videos.removeAll { $0.channelId == channelId } }
        })
    }
}
