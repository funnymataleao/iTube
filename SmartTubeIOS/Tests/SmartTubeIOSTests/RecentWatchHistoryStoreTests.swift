import Foundation
import Testing
@testable import SmartTubeIOSCore

@Suite("Recent Watch History Store")
struct RecentWatchHistoryStoreTests {
    private func makeStore() -> RecentWatchHistoryStore {
        RecentWatchHistoryStore(suiteName: "test-\(UUID().uuidString)")
    }

    @Test("Playback start is available immediately")
    func recordIsImmediatelyReadable() async {
        let store = makeStore()
        let video = Video(id: "new-video", title: "Just watched", channelTitle: "Channel")

        await store.record(video)

        let entries = await store.all
        #expect(entries.map(\.video.id) == ["new-video"])
    }

    @Test("Rewatching moves the video to the top without duplicates")
    func replayMovesToTop() async {
        let store = makeStore()
        await store.record(Video(id: "first", title: "First", channelTitle: "A"))
        await store.record(Video(id: "second", title: "Second", channelTitle: "B"))
        await store.record(Video(id: "first", title: "First again", channelTitle: "A"))

        let entries = await store.all
        #expect(entries.map(\.video.id) == ["first", "second"])
        #expect(entries[0].video.title == "First again")
    }

    @Test("History entries do not retain source playlist context")
    func playlistContextIsRemoved() async {
        let store = makeStore()
        let video = Video(
            id: "playlist-video",
            title: "Video",
            channelTitle: "Channel",
            playlistId: "PL123",
            playlistIndex: 7
        )

        await store.record(video)

        let saved = await store.all.first?.video
        #expect(saved?.playlistId == nil)
        #expect(saved?.playlistIndex == nil)
    }

    @Test("Entries persist across store recreation")
    func persists() async {
        let suite = "test-persist-\(UUID().uuidString)"
        let firstStore = RecentWatchHistoryStore(suiteName: suite)
        await firstStore.record(Video(id: "persisted", title: "Persisted", channelTitle: "Channel"))

        let secondStore = RecentWatchHistoryStore(suiteName: suite)
        #expect(await secondStore.all.map(\.video.id) == ["persisted"])
    }

    @Test("Videos returned by YouTube are removed from the pending local queue")
    func reconciliationRemovesOnlyServerMatches() async {
        let store = makeStore()
        await store.record(Video(id: "pending", title: "Pending", channelTitle: "Channel"))
        await store.record(Video(id: "server", title: "Server", channelTitle: "Channel"))

        await store.remove(videoIDs: ["server"])

        #expect(await store.all.map(\.video.id) == ["pending"])
    }

    @Test("History reconciliation keeps durable Home suppression")
    func reconciliationKeepsWatchedVideoID() async {
        let store = makeStore()
        await store.record(Video(id: "server", title: "Server", channelTitle: "Channel"))

        await store.remove(videoIDs: ["server"])

        #expect(await store.all.isEmpty)
        #expect(await store.watchedVideoIDs == ["server"])
    }

    @Test("Watched Home suppression persists after pending History reconciles")
    func watchedVideoIDsPersistAfterRecreation() async {
        let suite = "test-watched-persist-\(UUID().uuidString)"
        let firstStore = RecentWatchHistoryStore(suiteName: suite)
        await firstStore.record(Video(id: "watched", title: "Watched", channelTitle: "Channel"))
        await firstStore.remove(videoIDs: ["watched"])

        let secondStore = RecentWatchHistoryStore(suiteName: suite)

        #expect(await secondStore.all.isEmpty)
        #expect(await secondStore.watchedVideoIDs == ["watched"])
    }

    @Test("Only pending local videos precede the server's cross-device order")
    @MainActor
    func mergeKeepsImmediateVideoFirst() {
        let recent = [
            RecentWatchHistoryEntry(video: Video(id: "new", title: "Local", channelTitle: "Channel")),
            RecentWatchHistoryEntry(video: Video(id: "duplicate", title: "Local duplicate", channelTitle: "Channel")),
        ]
        let remote = [
            Video(id: "old", title: "Old", channelTitle: "Channel"),
            Video(id: "duplicate", title: "Remote metadata", channelTitle: "Channel"),
            Video(id: "older", title: "Older", channelTitle: "Channel"),
        ]

        let merged = BrowseViewModel.mergeHistory(recent: recent, remote: remote)

        #expect(merged.map(\.id) == ["new", "old", "duplicate", "older"])
        #expect(merged[2].title == "Remote metadata")
    }
}
