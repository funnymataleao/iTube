import Foundation

// MARK: - RecentWatchHistoryEntry

/// A locally observed playback start used to make History immediately consistent.
/// YouTube remains the long-term source of truth; these entries bridge the delay
/// between playback beginning and FEhistory reflecting the server-side stats ping.
public struct RecentWatchHistoryEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: String { video.id }
    public let video: Video
    public let watchedAt: Date

    public init(video: Video, watchedAt: Date = Date()) {
        var historyVideo = video
        // Queue/playlist context belongs to the source screen, not to History.
        historyVideo.playlistId = nil
        historyVideo.playlistIndex = nil
        self.video = historyVideo
        self.watchedAt = watchedAt
    }
}

/// On-disk state for both eventually-consistent History reconciliation and
/// durable Home recommendation suppression. The custom loader below also
/// accepts the legacy `[RecentWatchHistoryEntry]` payload used before the
/// watched-ID index was introduced.
struct RecentWatchHistorySnapshot: Codable, Sendable {
    var pendingEntries: [RecentWatchHistoryEntry]
    var watchedAtByVideoID: [String: Date]
}

// MARK: - RecentWatchHistoryStore

/// Persists recent playback starts so the History screen can update immediately,
/// without waiting for YouTube's eventually-consistent FEhistory endpoint.
public actor RecentWatchHistoryStore: UserDefaultsBackedStore {
    public static let shared = RecentWatchHistoryStore()

    static let defaultsKey = "st_recent_watch_history"
    private static let maxEntries = 200
    private static let maxWatchedVideoIDs = 1_000

    private var entries: [RecentWatchHistoryEntry] = []
    /// A durable, bounded index used by Home/Recommended. Unlike `entries`, IDs
    /// remain here after FEhistory has caught up so a completed reconciliation
    /// cannot make a watched recommendation reappear on the next refresh.
    private var watchedAtByVideoID: [String: Date] = [:]
    let defaults: UserDefaults

    private init() {
        self.defaults = .standard
        if let loaded = Self.loadSnapshot(from: .standard) {
            entries = loaded.pendingEntries
            watchedAtByVideoID = loaded.watchedAtByVideoID
        }
    }

    /// Designated initializer for unit tests with an isolated UserDefaults suite.
    init(suiteName: String) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        if let loaded = Self.loadSnapshot(from: self.defaults) {
            entries = loaded.pendingEntries
            watchedAtByVideoID = loaded.watchedAtByVideoID
        }
    }

    /// Entries sorted newest-first.
    public var all: [RecentWatchHistoryEntry] { entries }

    /// Video IDs that have actually started playback on this device, bounded to
    /// the most recent 1,000 items. History may reconcile and remove its pending
    /// entry, but Home still needs this index to suppress stale recommendations.
    public var watchedVideoIDs: Set<String> { Set(watchedAtByVideoID.keys) }

    /// Async-call-friendly snapshot used by injected feed providers.
    public func watchedVideoIDSnapshot() -> Set<String> { watchedVideoIDs }

    /// Records a real playback start. Replaying the same video moves it to the top.
    public func record(_ video: Video, watchedAt: Date = Date()) {
        guard !video.id.isEmpty else { return }
        entries.removeAll { $0.video.id == video.id }
        entries.insert(RecentWatchHistoryEntry(video: video, watchedAt: watchedAt), at: 0)
        watchedAtByVideoID[video.id] = watchedAt
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        pruneWatchedVideoIDsIfNeeded()
        persist()
    }

    /// Removes entries that YouTube now returns from FEhistory. Once reconciled,
    /// the server owns their ordering, including watches from other devices.
    public func remove(videoIDs: Set<String>) {
        guard !videoIDs.isEmpty else { return }
        let previousCount = entries.count
        entries.removeAll { videoIDs.contains($0.video.id) }
        if entries.count != previousCount { persist() }
    }

    public func clear() {
        entries = []
        watchedAtByVideoID = [:]
        persist()
    }

    func encodedValue() -> RecentWatchHistorySnapshot {
        RecentWatchHistorySnapshot(
            pendingEntries: entries,
            watchedAtByVideoID: watchedAtByVideoID
        )
    }

    func decodeValue(_ decoded: RecentWatchHistorySnapshot) {
        entries = decoded.pendingEntries
        watchedAtByVideoID = decoded.watchedAtByVideoID
    }

    /// Loads the new snapshot format, then falls back to the legacy array and
    /// seeds the watched-ID index from those pending entries during migration.
    private nonisolated static func loadSnapshot(
        from defaults: UserDefaults
    ) -> RecentWatchHistorySnapshot? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        if let snapshot = try? JSONDecoder().decode(RecentWatchHistorySnapshot.self, from: data) {
            return snapshot
        }
        guard let legacyEntries = try? JSONDecoder().decode(
            [RecentWatchHistoryEntry].self,
            from: data
        ) else { return nil }

        var watchedAtByVideoID: [String: Date] = [:]
        for entry in legacyEntries {
            watchedAtByVideoID[entry.video.id] = max(
                watchedAtByVideoID[entry.video.id] ?? .distantPast,
                entry.watchedAt
            )
        }
        return RecentWatchHistorySnapshot(
            pendingEntries: legacyEntries,
            watchedAtByVideoID: watchedAtByVideoID
        )
    }

    private func pruneWatchedVideoIDsIfNeeded() {
        guard watchedAtByVideoID.count > Self.maxWatchedVideoIDs else { return }
        let overflow = watchedAtByVideoID.count - Self.maxWatchedVideoIDs
        for (videoID, _) in watchedAtByVideoID
            .sorted(by: { $0.value < $1.value })
            .prefix(overflow) {
            watchedAtByVideoID.removeValue(forKey: videoID)
        }
    }
}
