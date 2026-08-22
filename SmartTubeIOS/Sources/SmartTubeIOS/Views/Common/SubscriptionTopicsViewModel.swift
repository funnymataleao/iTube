import Foundation
import Observation
import SmartTubeIOSCore

/// Enriches an already-loaded subscriptions snapshot without delaying the base
/// feed. The full feed remains usable when the documented metadata request fails.
@MainActor
@Observable
final class SubscriptionTopicsViewModel {
    typealias MetadataFetcher = @Sendable ([String]) async throws -> [String: VideoTopicMetadata]
    typealias ChannelVideosFetcher = @Sendable (String, String?) async throws -> VideoGroup
    typealias SubscribedChannelsFetcher = @Sendable () async throws -> [Channel]

    /// The first subscriptions page makes topics visible immediately. Channel
    /// archives then prefetch toward this target in the background and focus
    /// pagination keeps extending them afterwards.
    static let archivePrefetchTargetVideoCount = 120

    private struct ChannelArchive: Sendable {
        let channelID: String
        var nextPageToken: String?
        var hasRequestedFirstPage = false

        var canLoadMore: Bool {
            !hasRequestedFirstPage || nextPageToken != nil
        }
    }

    private struct TopicArchive: Sendable {
        var videos: [Video]
        var channels: [ChannelArchive]
    }

    private struct ArchiveBuildResult: Sendable {
        let topic: SubscriptionTopic
        let archive: TopicArchive?
        let errorDescription: String?
    }

    private let metadataFetcher: MetadataFetcher
    private let channelVideosFetcher: ChannelVideosFetcher
    private let subscribedChannelsFetcher: SubscribedChannelsFetcher
    private let cache: SubscriptionTopicMetadataCache
    private var requestGeneration = 0
    private var catalogGeneration = 0
    private var didPrepareCatalog = false
    private var archivesByTopic: [SubscriptionTopic: TopicArchive] = [:]
    private var loadingTopics: Set<SubscriptionTopic> = []
    private var exactPublishedAtByVideoID: [String: Date] = [:]
    private var exactDateRequestIDs: Set<String> = []
    private var exactDateGeneration = 0

    private(set) var topicsByVideoID: [String: SubscriptionTopic] = [:]
    /// Last fully classified feed snapshot. Filtered grids render this snapshot
    /// until the replacement classification is complete, preventing cards from
    /// moving between topics while metadata is still arriving.
    private(set) var classifiedVideos: [Video] = []
    private(set) var isLoading = false
    private(set) var isPreparingCatalog = false
    private(set) var nonfatalErrorDescription: String?
    /// Immediately published topic libraries. Internal `.other`
    /// classifications are deliberately never copied here.
    private(set) var catalogVideosByTopic: [SubscriptionTopic: [Video]] = [:]
    /// Stable control topology. Video counts may grow in the background without
    /// adding/removing focus targets one network response at a time.
    private(set) var availableCatalogTopics: [SubscriptionTopic] = []

    init(
        api: InnerTubeAPI,
        cache: SubscriptionTopicMetadataCache = .shared,
        metadataFetcher: MetadataFetcher? = nil,
        channelVideosFetcher: ChannelVideosFetcher? = nil,
        subscribedChannelsFetcher: SubscribedChannelsFetcher? = nil
    ) {
        self.cache = cache
        self.metadataFetcher = metadataFetcher ?? { videoIDs in
            try await api.fetchVideoTopicMetadata(videoIDs: videoIDs)
        }
        self.channelVideosFetcher = channelVideosFetcher ?? { channelID, continuationToken in
            try await api.fetchChannelVideos(
                channelId: channelID,
                continuationToken: continuationToken
            )
        }
        self.subscribedChannelsFetcher = subscribedChannelsFetcher ?? {
            try await api.fetchSubscribedChannels()
        }
    }

    func resetVisibleClassification() {
        requestGeneration += 1
        catalogGeneration += 1
        topicsByVideoID = [:]
        classifiedVideos = []
        isLoading = false
        isPreparingCatalog = false
        didPrepareCatalog = false
        archivesByTopic = [:]
        catalogVideosByTopic = [:]
        availableCatalogTopics = []
        exactPublishedAtByVideoID = [:]
        exactDateRequestIDs = []
        exactDateGeneration += 1
        loadingTopics = []
        nonfatalErrorDescription = nil
    }

    func enrich(videos: [Video]) async {
        let uniqueVideos = videos.reduce(into: [Video]()) { result, video in
            guard !video.id.isEmpty, !result.contains(where: { $0.id == video.id }) else { return }
            result.append(video)
        }
        guard !uniqueVideos.isEmpty else {
            topicsByVideoID = [:]
            classifiedVideos = []
            isLoading = false
            return
        }

        requestGeneration += 1
        let generation = requestGeneration
        isLoading = true
        nonfatalErrorDescription = nil

        let videoIDs = uniqueVideos.map(\.id)
        var metadataByVideoID = await cache.metadata(for: videoIDs)
        let missingIDs = videoIDs.filter { metadataByVideoID[$0] == nil }

        if !missingIDs.isEmpty {
            do {
                let fetched = try await metadataFetcher(missingIDs)
                guard generation == requestGeneration, !Task.isCancelled else { return }
                await cache.store(fetched)
                guard generation == requestGeneration, !Task.isCancelled else { return }
                metadataByVideoID.merge(fetched) { _, newest in newest }
            } catch {
                // Classification continues from titles/channel names. The base
                // subscriptions feed must never fail because enrichment failed.
                nonfatalErrorDescription = error.localizedDescription
            }
        }

        guard generation == requestGeneration, !Task.isCancelled else { return }
        recordExactPublishedDates(from: metadataByVideoID)
        let enrichedVideos = uniqueVideos.map(applyingExactPublishedAt)
        let replacementTopics = Dictionary(uniqueKeysWithValues: enrichedVideos.map { video in
            (
                video.id,
                SubscriptionTopicClassifier.topic(
                    for: video,
                    metadata: metadataByVideoID[video.id]
                )
            )
        })
        // Publish the data and its topic mapping in one MainActor turn. SwiftUI
        // never observes a half-classified feed.
        topicsByVideoID = replacementTopics
        classifiedVideos = enrichedVideos
        isLoading = false
    }

    /// Resolves coarse feed labels such as `Today` to YouTube's exact public
    /// timestamp in batches. This is intentionally independent from topic
    /// classification so subscription continuation pages can update their card
    /// labels without rebuilding controls or moving focus.
    func enrichPublishedDates(for videos: [Video]) async {
        let generation = exactDateGeneration
        let uniqueIDs = videos.reduce(into: [String]()) { result, video in
            guard !video.id.isEmpty,
                  exactPublishedAtByVideoID[video.id] == nil,
                  !exactDateRequestIDs.contains(video.id),
                  !result.contains(video.id)
            else { return }
            result.append(video.id)
        }
        guard !uniqueIDs.isEmpty else { return }

        exactDateRequestIDs.formUnion(uniqueIDs)
        defer {
            if generation == exactDateGeneration {
                exactDateRequestIDs.subtract(uniqueIDs)
            }
        }

        var metadata = await cache.metadata(for: uniqueIDs)
        guard generation == exactDateGeneration, !Task.isCancelled else { return }
        recordExactPublishedDates(from: metadata)

        let missingIDs = uniqueIDs.filter { metadata[$0] == nil }
        guard !missingIDs.isEmpty else { return }

        do {
            let fetched = try await metadataFetcher(missingIDs)
            guard generation == exactDateGeneration, !Task.isCancelled else { return }
            await cache.store(fetched)
            guard generation == exactDateGeneration, !Task.isCancelled else { return }
            metadata.merge(fetched) { _, newest in newest }
            recordExactPublishedDates(from: metadata)
        } catch {
            // Existing cards remain visible. A later refresh or pagination pass
            // may retry; no loading placeholder is inserted into the grid.
            nonfatalErrorDescription = error.localizedDescription
        }
    }

    func topic(for video: Video) -> SubscriptionTopic {
        topicsByVideoID[video.id]
            ?? SubscriptionTopicClassifier.topic(for: video, metadata: nil)
    }

    func counts(in _: [Video]) -> [SubscriptionTopic: Int] {
        classifiedVideos.reduce(into: [SubscriptionTopic: Int]()) { result, video in
            guard let topic = topicsByVideoID[video.id] else { return }
            result[topic, default: 0] += 1
        }
    }

    func videos(
        in selectedTopic: SubscriptionTopic,
        from videos: [Video]
    ) -> [Video] {
        guard selectedTopic != .all else { return videos }
        return classifiedVideos.filter { topicsByVideoID[$0.id] == selectedTopic }
    }

    var catalogCounts: [SubscriptionTopic: Int] {
        catalogVideosByTopic.mapValues(\.count)
    }

    func catalogVideos(
        in selectedTopic: SubscriptionTopic,
        allVideos: [Video]
    ) -> [Video] {
        guard selectedTopic != .all else {
            // Exact dates can arrive after the base InnerTube snapshot. Always
            // derive All Subscriptions from the best timestamp currently known
            // so an old dated card never outranks a fresh previously-undated one.
            return Self.stableNewestFirst(allVideos.map(applyingExactPublishedAt))
        }
        // Every topic follows the same freshness contract as All Subscriptions.
        // Exact dates can arrive after the archive itself, so derive the visible
        // snapshot from the best timestamps currently known on every read.
        return Self.stableNewestFirst(
            (catalogVideosByTopic[selectedTopic] ?? []).map(applyingExactPublishedAt)
        )
    }

    func isLoadingMore(in topic: SubscriptionTopic) -> Bool {
        loadingTopics.contains(topic)
    }

    /// Re-fetches the channel archives while keeping the currently published
    /// catalogue on screen, so Refresh never collapses the grid to zero cards.
    func refreshCatalog(from videos: [Video]) async {
        // Latest refresh wins. Invalidate an older background build without
        // clearing its already-visible cards; its generation guards prevent it
        // from publishing after this point.
        catalogGeneration += 1
        didPrepareCatalog = false
        isPreparingCatalog = false
        loadingTopics = []
        await prepareCatalog(from: videos)
    }

    /// Publishes topics from the first page immediately, then grows every topic
    /// from full subscribed-channel archives in the background.
    func prepareCatalog(from videos: [Video]) async {
        guard !videos.isEmpty, !didPrepareCatalog, !isPreparingCatalog else { return }
        let generation = catalogGeneration
        didPrepareCatalog = true
        isPreparingCatalog = true
        defer {
            if generation == catalogGeneration {
                isPreparingCatalog = false
            }
        }

        let retainsPreviousCatalog = !catalogVideosByTopic.isEmpty
        let previousCatalog = catalogVideosByTopic
        let previousArchives = archivesByTopic
        var seedVideos = Self.uniqueWatchableVideos(videos)
        let videoIDs = seedVideos.map(\.id)
        // The control row must never wait for network classification. Cached
        // metadata and title/channel fallbacks produce a useful first frame.
        var catalogMetadata = await cache.metadata(for: videoIDs)
        guard generation == catalogGeneration, !Task.isCancelled else { return }
        recordExactPublishedDates(from: catalogMetadata)
        seedVideos = seedVideos.map(applyingExactPublishedAt)
        var catalogTopicsByVideoID = Dictionary(uniqueKeysWithValues: seedVideos.map { video in
            (
                video.id,
                SubscriptionTopicClassifier.topic(
                    for: video,
                    metadata: catalogMetadata[video.id]
                )
            )
        })
        var replacementCatalog = Self.seedCatalog(
            seedVideos,
            topicsByVideoID: catalogTopicsByVideoID
        )
        if !retainsPreviousCatalog {
            // Initial load: expose useful seed categories immediately. Archive
            // growth and later metadata never mutate this control topology one
            // response at a time.
            catalogVideosByTopic = replacementCatalog
            availableCatalogTopics = Self.orderedTopics(in: replacementCatalog)
        }

        let missingMetadataIDs = videoIDs.filter { catalogMetadata[$0] == nil }
        if !missingMetadataIDs.isEmpty {
            do {
                // This is only the first visible subscriptions page, not the
                // full continuation chain. One small metadata batch gives a
                // fresh install reliable YouTube category IDs without making
                // the user wait for hundreds of per-video requests.
                let fetched = try await metadataFetcher(missingMetadataIDs)
                guard generation == catalogGeneration, !Task.isCancelled else { return }
                await cache.store(fetched)
                guard generation == catalogGeneration, !Task.isCancelled else { return }
                catalogMetadata.merge(fetched) { _, newest in newest }
                recordExactPublishedDates(from: catalogMetadata)
                seedVideos = seedVideos.map(applyingExactPublishedAt)

                // Never move a card out of an already-visible topic while the
                // user is navigating. Metadata may only promote an initially
                // unclassified card into a useful category.
                for video in seedVideos where catalogTopicsByVideoID[video.id] == .other {
                    let refinedTopic = SubscriptionTopicClassifier.topic(
                        for: video,
                        metadata: catalogMetadata[video.id]
                    )
                    if refinedTopic != .other {
                        catalogTopicsByVideoID[video.id] = refinedTopic
                    }
                }
                replacementCatalog = Self.seedCatalog(
                    seedVideos,
                    topicsByVideoID: catalogTopicsByVideoID
                )
                if !retainsPreviousCatalog {
                    // Update card data atomically, but keep the initial control
                    // IDs stable until the completed catalogue is published.
                    catalogVideosByTopic = replacementCatalog
                }
            } catch {
                // Channel/title classification below is the offline-compatible
                // fallback; category controls still become usable.
                if generation == catalogGeneration, !Task.isCancelled {
                    nonfatalErrorDescription = error.localizedDescription
                }
            }
        }
        var channelIDByKey: [String: String] = [:]
        for video in seedVideos {
            guard let channelID = video.channelId, !channelID.isEmpty else { continue }
            channelIDByKey[Self.channelKey(for: video)] = channelID
        }
        var subscribedChannels: [Channel] = []
        do {
            subscribedChannels = try await subscribedChannelsFetcher()
            guard generation == catalogGeneration, !Task.isCancelled else { return }
            for channel in subscribedChannels where !channel.id.isEmpty {
                let key = Self.normalizedChannelKey(channel.title)
                guard !key.isEmpty else { continue }
                channelIDByKey[key] = channel.id
            }
        } catch {
            if generation == catalogGeneration, !Task.isCancelled {
                nonfatalErrorDescription = error.localizedDescription
            }
        }

        var channelKeysByTopic: [SubscriptionTopic: [String]] = [:]

        for video in seedVideos {
            let topic = catalogTopicsByVideoID[video.id]
                ?? SubscriptionTopicClassifier.topic(for: video, metadata: nil)
            guard topic != .all, topic != .other else { continue }
            let channelKey = Self.channelKey(for: video)
            guard !channelKey.isEmpty else { continue }
            if channelKeysByTopic[topic]?.contains(channelKey) != true {
                channelKeysByTopic[topic, default: []].append(channelKey)
            }
        }

        // The guide contains the complete subscribed-channel list. Promote
        // channels whose names clearly identify a topic even when that channel
        // did not happen to publish on the first subscriptions page. This makes
        // the catalogue broader without inventing categories or exposing empty
        // controls.
        for channel in subscribedChannels where !channel.id.isEmpty {
            let channelKey = Self.normalizedChannelKey(channel.title)
            guard !channelKey.isEmpty else { continue }
            let channelProbe = Video(
                id: "subscription-channel-\(channel.id)",
                title: channel.title,
                channelTitle: channel.title,
                channelId: channel.id
            )
            let topic = SubscriptionTopicClassifier.topic(for: channelProbe, metadata: nil)
            guard topic != .all, topic != .other else { continue }
            if channelKeysByTopic[topic]?.contains(channelKey) != true {
                channelKeysByTopic[topic, default: []].append(channelKey)
            }
        }

        let orderedTopics = channelKeysByTopic.keys.sorted { lhs, rhs in
            let lhsCount = seedVideos.filter { catalogTopicsByVideoID[$0.id] == lhs }.count
            let rhsCount = seedVideos.filter { catalogTopicsByVideoID[$0.id] == rhs }.count
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return lhs.rawValue < rhs.rawValue
        }

        var archiveInputs: [(SubscriptionTopic, TopicArchive)] = []
        for topic in orderedTopics {
            guard let channelKeys = channelKeysByTopic[topic], !channelKeys.isEmpty else { continue }
            let channelKeySet = Set(channelKeys)
            let initialVideos = seedVideos.filter { video in
                channelKeySet.contains(Self.channelKey(for: video))
            }
            var seenChannelIDs: Set<String> = []
            let channelIDs = channelKeys.compactMap { channelKey -> String? in
                guard let channelID = channelIDByKey[channelKey],
                      seenChannelIDs.insert(channelID).inserted
                else { return nil }
                return channelID
            }
            let archive = TopicArchive(
                videos: initialVideos,
                channels: channelIDs.map {
                    ChannelArchive(channelID: $0, nextPageToken: nil)
                }
            )
            archiveInputs.append((topic, archive))
        }

        let fetcher = channelVideosFetcher
        let maximumConcurrentTopicBuilds = 4
        var replacementArchives: [SubscriptionTopic: TopicArchive] = [:]
        var failedTopics: Set<SubscriptionTopic> = []
        await withTaskGroup(of: ArchiveBuildResult.self) { group in
            var nextInputIndex = 0

            func enqueueNextArchive() {
                guard nextInputIndex < archiveInputs.count else { return }
                let (topic, archive) = archiveInputs[nextInputIndex]
                nextInputIndex += 1
                group.addTask {
                    await Self.buildArchive(
                        topic: topic,
                        archive: archive,
                        targetCount: Self.archivePrefetchTargetVideoCount,
                        fetcher: fetcher
                    )
                }
            }

            for _ in 0..<min(maximumConcurrentTopicBuilds, archiveInputs.count) {
                enqueueNextArchive()
            }

            while let result = await group.next() {
                guard generation == catalogGeneration, !Task.isCancelled else { continue }
                // Keep the bounded queue moving even if this topic produced no
                // archive. One failed channel must not starve later topics.
                enqueueNextArchive()
                if let errorDescription = result.errorDescription {
                    nonfatalErrorDescription = errorDescription
                    failedTopics.insert(result.topic)
                }
                guard var archive = result.archive else { continue }
                // The control already exists from the first page. Publish one
                // complete newest-first snapshot rather than exposing partial
                // page-by-page mutations.
                archive.videos = Self.stableNewestFirst(
                    archive.videos.map(applyingExactPublishedAt)
                )
                replacementArchives[result.topic] = archive
                replacementCatalog[result.topic] = archive.videos
            }
        }

        guard generation == catalogGeneration, !Task.isCancelled else { return }
        replacementCatalog = replacementCatalog.filter { !$0.value.isEmpty }

        if retainsPreviousCatalog {
            // Refresh is a replacement only for topics that were rebuilt
            // successfully. A transient channel failure or a sparse new seed
            // must not collapse a category from hundreds of cards to one, or
            // remove its focus target while the user is navigating.
            for (topic, oldVideos) in previousCatalog where topic != .all {
                let shouldRetainOld = replacementCatalog[topic] == nil
                    || (failedTopics.contains(topic)
                        && oldVideos.count > (replacementCatalog[topic]?.count ?? 0))
                guard shouldRetainOld else { continue }
                replacementCatalog[topic] = oldVideos
                if let oldArchive = previousArchives[topic] {
                    replacementArchives[topic] = oldArchive
                }
            }
        }

        archivesByTopic = replacementArchives.filter {
            replacementCatalog[$0.key]?.isEmpty == false
        }
        catalogVideosByTopic = replacementCatalog
        availableCatalogTopics = Self.orderedTopics(in: replacementCatalog)

        // Make the hundreds of archive cards available immediately. Their exact
        // minute/hour timestamps are enriched in a background batch, then each
        // topic is re-sorted and published atomically without partial states.
        let archiveVideos = Self.uniqueWatchableVideos(
            archivesByTopic.values.flatMap(\.videos)
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.enrichPublishedDates(for: archiveVideos)
            guard generation == self.catalogGeneration, !Task.isCancelled else { return }
            self.applyExactPublishedDatesToPublishedArchives()
        }
    }

    /// Loads one continuation round for the selected topic and atomically merges
    /// it into the same exact newest-first order used by the initial archive.
    func loadMore(in topic: SubscriptionTopic) async {
        guard topic != .all,
              !loadingTopics.contains(topic),
              var archive = archivesByTopic[topic]
        else { return }

        let generation = catalogGeneration
        loadingTopics.insert(topic)
        defer {
            if generation == catalogGeneration {
                loadingTopics.remove(topic)
            }
        }

        let previousIDs = Set(archive.videos.map(\.id))
        var appendedVideos: [Video] = []

        for index in archive.channels.indices where archive.channels[index].canLoadMore {
            let page = await fetchNextPage(
                for: &archive.channels[index],
                generation: generation
            )
            guard generation == catalogGeneration, !Task.isCancelled else { return }
            appendedVideos.append(contentsOf: page)
        }

        guard generation == catalogGeneration, !Task.isCancelled else { return }
        var genuinelyNew = Self.uniqueWatchableVideos(appendedVideos).filter {
            !previousIDs.contains($0.id)
        }
        guard !genuinelyNew.isEmpty else {
            archivesByTopic[topic] = archive
            return
        }

        await enrichPublishedDates(for: genuinelyNew)
        guard generation == catalogGeneration, !Task.isCancelled else { return }
        genuinelyNew = genuinelyNew.map(applyingExactPublishedAt)

        archive.videos.append(contentsOf: genuinelyNew)
        archive.videos = Self.stableNewestFirst(
            archive.videos.map(applyingExactPublishedAt)
        )
        archivesByTopic[topic] = archive
        catalogVideosByTopic[topic] = archive.videos
    }

    nonisolated private static func buildArchive(
        topic: SubscriptionTopic,
        archive initialArchive: TopicArchive,
        targetCount: Int,
        fetcher: ChannelVideosFetcher
    ) async -> ArchiveBuildResult {
        var archive = initialArchive
        archive.videos = uniqueWatchableVideos(archive.videos)
        var lastErrorDescription: String?
        var failedChannelIndexes: Set<Int> = []

        while archive.videos.count < targetCount || archive.channels.indices.contains(where: {
            !archive.channels[$0].hasRequestedFirstPage && !failedChannelIndexes.contains($0)
        }) {
            var madeRequest = false

            for index in archive.channels.indices
            where archive.channels[index].canLoadMore && !failedChannelIndexes.contains(index) {
                let needsFirstPage = !archive.channels[index].hasRequestedFirstPage
                // Reaching the target never skips an unseen channel: its first
                // page may contain the newest upload in this topic. Only
                // continuation pages are deferred to focus pagination.
                guard needsFirstPage || archive.videos.count < targetCount else { continue }
                madeRequest = true
                let requestedToken = archive.channels[index].hasRequestedFirstPage
                    ? archive.channels[index].nextPageToken
                    : nil

                do {
                    let group = try await fetchChannelPageWithRetry(
                        channelID: archive.channels[index].channelID,
                        continuationToken: requestedToken,
                        fetcher: fetcher
                    )
                    archive.channels[index].hasRequestedFirstPage = true
                    archive.channels[index].nextPageToken =
                        group.nextPageToken == requestedToken && requestedToken != nil
                        ? nil
                        : group.nextPageToken
                    let knownIDs = Set(archive.videos.map(\.id))
                    archive.videos.append(
                        contentsOf: uniqueWatchableVideos(group.videos).filter {
                            !knownIDs.contains($0.id)
                        }
                    )
                } catch {
                    // Keep the continuation state intact. A temporary network
                    // failure must not permanently mark this channel as fully
                    // consumed; a later focus-pagination pass can try again.
                    failedChannelIndexes.insert(index)
                    lastErrorDescription = error.localizedDescription
                }

                if Task.isCancelled { break }
            }

            guard madeRequest, !Task.isCancelled else { break }
        }

        guard !archive.videos.isEmpty else {
            return ArchiveBuildResult(
                topic: topic,
                archive: nil,
                errorDescription: lastErrorDescription
            )
        }
        return ArchiveBuildResult(
            topic: topic,
            archive: archive,
            errorDescription: lastErrorDescription
        )
    }

    nonisolated private static func seedCatalog(
        _ seedVideos: [Video],
        topicsByVideoID: [String: SubscriptionTopic]
    ) -> [SubscriptionTopic: [Video]] {
        var seedVideosByTopic: [SubscriptionTopic: [Video]] = [:]
        for video in seedVideos {
            guard let topic = topicsByVideoID[video.id],
                  topic != .all,
                  topic != .other
            else { continue }
            seedVideosByTopic[topic, default: []].append(video)
        }
        return seedVideosByTopic.mapValues(uniqueWatchableVideos)
    }

    nonisolated private static func orderedTopics(
        in catalog: [SubscriptionTopic: [Video]]
    ) -> [SubscriptionTopic] {
        SubscriptionTopic.classifiedCases.filter { catalog[$0]?.isEmpty == false }
    }

    private func recordExactPublishedDates(
        from metadataByVideoID: [String: VideoTopicMetadata]
    ) {
        for (videoID, metadata) in metadataByVideoID {
            if let publishedAt = metadata.publishedAt {
                exactPublishedAtByVideoID[videoID] = publishedAt
            }
        }
    }

    private func applyingExactPublishedAt(to video: Video) -> Video {
        guard let publishedAt = exactPublishedAtByVideoID[video.id] else { return video }
        var enriched = video
        enriched.publishedAt = publishedAt
        enriched.exactPublishedAt = publishedAt
        return enriched
    }

    private func applyExactPublishedDatesToPublishedArchives() {
        for topic in Array(archivesByTopic.keys) {
            guard var archive = archivesByTopic[topic] else { continue }
            archive.videos = Self.stableNewestFirst(
                archive.videos.map(applyingExactPublishedAt)
            )
            archivesByTopic[topic] = archive
            catalogVideosByTopic[topic] = archive.videos
        }
    }

    private func fetchNextPage(
        for archive: inout ChannelArchive,
        generation: Int
    ) async -> [Video] {
        guard archive.canLoadMore else { return [] }

        let requestedToken = archive.hasRequestedFirstPage ? archive.nextPageToken : nil

        do {
            let group = try await Self.fetchChannelPageWithRetry(
                channelID: archive.channelID,
                continuationToken: requestedToken,
                fetcher: channelVideosFetcher
            )
            archive.hasRequestedFirstPage = true
            // A repeated continuation would otherwise create an infinite fetch
            // loop on a malformed/expired YouTube response.
            archive.nextPageToken = group.nextPageToken == requestedToken && requestedToken != nil
                ? nil
                : group.nextPageToken
            return group.videos
        } catch {
            // Preserve the request state so returning focus to the end of this
            // category can retry after a transient YouTube/network failure.
            if generation == catalogGeneration, !Task.isCancelled {
                nonfatalErrorDescription = error.localizedDescription
            }
            return []
        }
    }

    nonisolated private static func fetchChannelPageWithRetry(
        channelID: String,
        continuationToken: String?,
        fetcher: ChannelVideosFetcher
    ) async throws -> VideoGroup {
        var lastError: Error?
        let backoffNanoseconds: [UInt64] = [250_000_000, 600_000_000]

        for attempt in 0...backoffNanoseconds.count {
            do {
                return try await fetcher(channelID, continuationToken)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt < backoffNanoseconds.count else { break }
                try await Task<Never, Never>.sleep(
                    nanoseconds: backoffNanoseconds[attempt]
                )
            }
        }

        throw lastError ?? CancellationError()
    }

    nonisolated private static func uniqueWatchableVideos(_ videos: [Video]) -> [Video] {
        var seenIDs: Set<String> = []
        return videos.filter { video in
            guard !video.id.isEmpty,
                  !video.isShort,
                  !video.isLive,
                  !video.isUpcoming,
                  seenIDs.insert(video.id).inserted
            else { return false }
            return true
        }
    }

    /// Relative publish labels are coarse (many cards can all be "Today" or
    /// "1 day ago"). Keep YouTube's server order inside a one-minute bucket so
    /// equal-date cards never shuffle nondeterministically.
    nonisolated private static func stableNewestFirst(_ videos: [Video]) -> [Video] {
        uniqueWatchableVideos(videos)
            .enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.publishedAt, rhs.element.publishedAt) {
                case let (leftDate?, rightDate?):
                    let difference = leftDate.timeIntervalSince(rightDate)
                    if abs(difference) >= 60 { return difference > 0 }
                    return lhs.offset < rhs.offset
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    nonisolated private static func channelKey(for video: Video) -> String {
        let titleKey = normalizedChannelKey(video.channelTitle)
        if !titleKey.isEmpty { return titleKey }
        return video.channelId ?? ""
    }

    nonisolated private static func normalizedChannelKey(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

}
