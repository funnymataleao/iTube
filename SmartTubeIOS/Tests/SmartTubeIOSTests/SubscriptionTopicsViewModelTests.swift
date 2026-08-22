import Foundation
import Testing
@testable import SmartTubeIOS
@testable import SmartTubeIOSCore

private actor MetadataFetchGate {
    private var didStart = false
    private var continuation: CheckedContinuation<[String: VideoTopicMetadata], Never>?

    func fetch(videoIDs _: [String]) async -> [String: VideoTopicMetadata] {
        didStart = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        while !didStart {
            await Task.yield()
        }
    }

    func finish(with metadata: [String: VideoTopicMetadata]) {
        continuation?.resume(returning: metadata)
        continuation = nil
    }
}

private actor ChannelFetchGate {
    private var didStart = false
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func fetch(channelID: String, continuationToken: String?) async -> VideoGroup {
        if !isOpen {
            didStart = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        let page = Int(continuationToken ?? "0") ?? 0
        return VideoGroup(
            videos: (1...30).map { index in
                Video(
                    id: "gaming-\(page)-\(index)",
                    title: "Game archive \(page)-\(index)",
                    channelTitle: "Game Room",
                    channelId: channelID
                )
            },
            nextPageToken: page < 7 ? String(page + 1) : nil
        )
    }

    func waitUntilStarted() async {
        while !didStart {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
@Suite("Subscription topic snapshot stability")
struct SubscriptionTopicsViewModelTests {
    @Test("Filtered videos stay stable until replacement classification is complete")
    func keepsPreviousSnapshotWhileMetadataLoads() async {
        let suiteName = "SubscriptionTopicsViewModelTests.\(UUID().uuidString)"
        let cache = SubscriptionTopicMetadataCache(suiteName: suiteName)
        await cache.clear()

        let previousVideo = Video(
            id: "previous-gaming",
            title: "Weekly roundup",
            channelTitle: "Channel"
        )
        await cache.store([
            previousVideo.id: VideoTopicMetadata(
                videoID: previousVideo.id,
                categoryID: "20",
                tags: []
            )
        ])

        let gate = MetadataFetchGate()
        let model = SubscriptionTopicsViewModel(
            api: InnerTubeAPI(),
            cache: cache,
            metadataFetcher: { videoIDs in
                await gate.fetch(videoIDs: videoIDs)
            }
        )

        await model.enrich(videos: [previousVideo])
        #expect(model.videos(in: .gaming, from: [previousVideo]).map(\.id) == [previousVideo.id])

        let replacementVideo = Video(
            id: "replacement-science",
            title: "A new discovery",
            channelTitle: "Lab"
        )
        let replacementTask = Task {
            await model.enrich(videos: [replacementVideo])
        }

        await gate.waitUntilStarted()

        #expect(model.isLoading)
        #expect(model.classifiedVideos.map(\.id) == [previousVideo.id])
        #expect(model.videos(in: .gaming, from: [replacementVideo]).map(\.id) == [previousVideo.id])

        await gate.finish(with: [
            replacementVideo.id: VideoTopicMetadata(
                videoID: replacementVideo.id,
                categoryID: "28",
                tags: ["physics"]
            )
        ])
        await replacementTask.value

        #expect(!model.isLoading)
        #expect(model.classifiedVideos.map(\.id) == [replacementVideo.id])
        #expect(model.videos(in: .gaming, from: [replacementVideo]).isEmpty)
        #expect(model.videos(in: .science, from: [replacementVideo]).map(\.id) == [replacementVideo.id])

        await cache.clear()
    }

    @Test("A topic is visible immediately and its channel archive grows past 120 videos")
    func buildsSubstantialChannelArchiveAndPaginates() async {
        let suiteName = "SubscriptionTopicsCatalogTests.\(UUID().uuidString)"
        let cache = SubscriptionTopicMetadataCache(suiteName: suiteName)
        await cache.clear()

        let seed = Video(
            id: "gaming-seed",
            title: "Gaming weekly roundup",
            channelTitle: "Game Room",
            channelId: "gaming-channel"
        )
        let uncategorized = Video(
            id: "other-seed",
            title: "A regular upload",
            channelTitle: "Personal Channel",
            channelId: "other-channel"
        )

        let channelGate = ChannelFetchGate()
        let model = SubscriptionTopicsViewModel(
            api: InnerTubeAPI(),
            cache: cache,
            metadataFetcher: { videoIDs in
                Dictionary(uniqueKeysWithValues: videoIDs.map { videoID in
                    let categoryID = videoID == seed.id ? "20" : nil
                    return (
                        videoID,
                        VideoTopicMetadata(
                            videoID: videoID,
                            categoryID: categoryID,
                            tags: []
                        )
                    )
                })
            },
            channelVideosFetcher: { channelID, continuationToken in
                await channelGate.fetch(
                    channelID: channelID,
                    continuationToken: continuationToken
                )
            },
            subscribedChannelsFetcher: {
                []
            }
        )

        let prepareTask = Task {
            await model.prepareCatalog(from: [seed, uncategorized])
        }
        await channelGate.waitUntilStarted()

        #expect(model.catalogCounts[.gaming] == 1)
        #expect(model.catalogCounts[.other] == nil)

        await channelGate.open()
        await prepareTask.value

        #expect(model.catalogCounts[.gaming] == 121)
        #expect(model.catalogCounts[.other] == nil)
        #expect(model.catalogVideos(in: .gaming, allVideos: []).count == 121)

        await model.loadMore(in: .gaming)
        #expect(model.catalogCounts[.gaming] == 151)

        await cache.clear()
    }

    @Test("A completed topic archive publishes newest videos first once")
    func completedArchivePublishesNewestFirst() async {
        let suiteName = "SubscriptionTopicsNewestArchiveTests.\(UUID().uuidString)"
        let cache = SubscriptionTopicMetadataCache(suiteName: suiteName)
        await cache.clear()

        let now = Date()
        let seed = Video(
            id: "gaming-seed-old",
            title: "Gaming weekly roundup",
            channelTitle: "Game Room",
            channelId: "gaming-channel",
            publishedAt: now.addingTimeInterval(-5 * 86_400)
        )
        let newest = Video(
            id: "gaming-today",
            title: "Gaming today",
            channelTitle: "Game Room",
            channelId: "gaming-channel",
            publishedAt: now
        )
        let middle = Video(
            id: "gaming-two-days",
            title: "Gaming two days ago",
            channelTitle: "Game Room",
            channelId: "gaming-channel",
            publishedAt: now.addingTimeInterval(-2 * 86_400)
        )

        let model = SubscriptionTopicsViewModel(
            api: InnerTubeAPI(),
            cache: cache,
            metadataFetcher: { videoIDs in
                Dictionary(uniqueKeysWithValues: videoIDs.map { videoID in
                    (
                        videoID,
                        VideoTopicMetadata(videoID: videoID, categoryID: "20", tags: [])
                    )
                })
            },
            channelVideosFetcher: { _, _ in
                VideoGroup(videos: [newest, middle], nextPageToken: nil)
            },
            subscribedChannelsFetcher: { [] }
        )

        await model.prepareCatalog(from: [seed])

        #expect(model.catalogVideos(in: .gaming, allVideos: []).map(\.id) == [
            newest.id, middle.id, seed.id
        ])

        await cache.clear()
    }

    @Test("Exact metadata replaces a coarse Today label without rebuilding topics")
    func enrichesExactPublishAgeIndependently() async {
        let suiteName = "SubscriptionTopicsExactDateTests.\(UUID().uuidString)"
        let cache = SubscriptionTopicMetadataCache(suiteName: suiteName)
        await cache.clear()

        let now = Date()
        let exactDate = now.addingTimeInterval(-2 * 3_600)
        let video = Video(
            id: "coarse-today",
            title: "Recent upload",
            channelTitle: "Channel",
            publishedAt: now,
            publishedTimeText: "Today"
        )
        let model = SubscriptionTopicsViewModel(
            api: InnerTubeAPI(),
            cache: cache,
            metadataFetcher: { videoIDs in
                Dictionary(uniqueKeysWithValues: videoIDs.map { videoID in
                    (
                        videoID,
                        VideoTopicMetadata(
                            videoID: videoID,
                            categoryID: "24",
                            tags: [],
                            publishedAt: exactDate
                        )
                    )
                })
            },
            channelVideosFetcher: { _, _ in VideoGroup() },
            subscribedChannelsFetcher: { [] }
        )

        await model.enrichPublishedDates(for: [video])
        let enriched = model.catalogVideos(in: .all, allVideos: [video]).first

        #expect(enriched?.publishedAt == exactDate)
        #expect(enriched?.exactPublishedAt == exactDate)
        #expect(
            enriched.flatMap {
                VideoPublishAgeFormatter.label(for: $0, relativeTo: now)
            } != nil
        )

        await cache.clear()
    }

    @Test("Every topic uses exact newest-first order")
    func exactNewestFirstAppliesToFilteredTopics() async {
        let suiteName = "SubscriptionTopicsExactTopicOrderTests.\(UUID().uuidString)"
        let cache = SubscriptionTopicMetadataCache(suiteName: suiteName)
        await cache.clear()

        let now = Date()
        let oldVideo = Video(
            id: "gaming-old-dated",
            title: "Old gaming upload",
            channelTitle: "Game Room",
            publishedAt: now.addingTimeInterval(-14 * 86_400)
        )
        let freshInitiallyUndatedVideo = Video(
            id: "gaming-fresh-undated",
            title: "Fresh gaming upload",
            channelTitle: "Game Room"
        )
        let model = SubscriptionTopicsViewModel(
            api: InnerTubeAPI(),
            cache: cache,
            metadataFetcher: { _ in
                [
                    oldVideo.id: VideoTopicMetadata(
                        videoID: oldVideo.id,
                        categoryID: "20",
                        tags: [],
                        publishedAt: now.addingTimeInterval(-14 * 86_400)
                    ),
                    freshInitiallyUndatedVideo.id: VideoTopicMetadata(
                        videoID: freshInitiallyUndatedVideo.id,
                        categoryID: "20",
                        tags: [],
                        publishedAt: now.addingTimeInterval(-10 * 60)
                    ),
                ]
            },
            channelVideosFetcher: { _, _ in VideoGroup() },
            subscribedChannelsFetcher: { [] }
        )

        await model.prepareCatalog(from: [oldVideo, freshInitiallyUndatedVideo])

        #expect(model.catalogVideos(in: .gaming, allVideos: []).map(\.id) == [
            freshInitiallyUndatedVideo.id, oldVideo.id
        ])

        await cache.clear()
    }
}
