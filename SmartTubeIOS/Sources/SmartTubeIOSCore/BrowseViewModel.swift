import Foundation
import Observation
import os

private let browseLog = ViewModelLogger(category: "Browse")

// MARK: - BrowseError

public enum BrowseError: LocalizedError {
    case timeout

    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "The feed took too long to load. Check your connection and try again."
        }
    }
}

// MARK: - BrowseViewModel
//
// Drives the main browse screen.  Mirrors the Android `BrowsePresenter`.

@MainActor
@Observable
public final class BrowseViewModel {

    /// YouTube's TV subscriptions response is relevance-biased: the freshest
    /// upload can be on page two or three. Build one bounded exact-date window
    /// before publishing, then let ordinary scrolling append older pages.
    private static let initialSubscriptionSnapshotPageLimit = 4

    // MARK: - State

    public private(set) var sections: [BrowseSection] = BrowseSection.defaultSections
    public private(set) var currentSection: BrowseSection = BrowseSection.defaultSections[0]
    public private(set) var videoGroups: [VideoGroup] = []
    /// Populated when the current section is `.channels`; empty for all other sections.
    public private(set) var subscribedChannels: [Channel] = []
    public private(set) var isLoading: Bool = false
    /// Becomes true only after the active section's first load attempt finishes.
    /// Views use this to distinguish the initial `.idle` frame from a genuine
    /// empty result, so an empty-state message never flashes before loading starts.
    public private(set) var hasCompletedInitialLoad: Bool = false
    /// True while a pagination (loadMore) request is in flight. Distinct from `isLoading`,
    /// which covers the initial/refresh fetch. Keeping these separate prevents the preload
    /// cache work that follows the initial fetch from blocking subsequent loadMore calls.
    public private(set) var isLoadingMore: Bool = false
    /// Whether the active flat feed has another continuation page available.
    /// Topic-filtered subscriptions use this to keep paging until enough matching
    /// cards are visible instead of presenting a false empty state.
    public var hasMoreContent: Bool { videoGroups.last?.nextPageToken != nil }
    /// Shelves currently fetching their own horizontal continuation page.
    /// Each Home carousel paginates independently from the vertical Home feed.
    private var loadingHomeShelfIDs: Set<UUID> = []
    public var error: Error?
    /// True when the current section requires authentication and the user is not signed in.
    public private(set) var isAuthRequired: Bool = false
    /// Shorts fetched from FEshorts for the Recommended section.
    /// Always empty for all other sections.
    public private(set) var recommendedShortsVideos: [Video] = []
    /// Timestamp of the last successful content fetch for the current section.
    /// Used to detect stale feeds after the app returns from background.
    public private(set) var loadedAt: Date? = nil
    /// A video to open immediately via deeplink / URL interception.
    /// Cleared by the UI after the player is presented.
    public var deepLinkedVideo: Video?

    // MARK: - Dependencies

    private let api: any InnerTubeAPIProtocol
    private let watchedVideoIDsProvider: @Sendable () async -> Set<String>
    private let subscriptionMetadataCache: SubscriptionTopicMetadataCache
    private var fetchTask: Task<Void, Never>?
    /// Identifies the latest initial/refresh request. A cancelled request can
    /// finish after its replacement has started; only the latest request may
    /// publish terminal loading state.
    private var contentLoadRevision: UInt = 0
    private var enrichTask: Task<Void, Never>?
    /// When `false`, the History section returns empty content rather than fetching from YouTube.
    private var historyEnabled: Bool = true
    /// Counts consecutive pages fetched for the Shorts chip that produced 0 new unique videos
    /// (all results were already in the list). After 3 consecutive empty pages we clear the
    /// nextPageToken so the scroll-trigger sentinel cannot loop forever on a sparse result set.
    private var consecutiveEmptyShortPages: Int = 0
    /// True when the Recommended section fell back to a `/search?q=popular` result
    /// because the unauthenticated `/browse` home feed returned 0 videos.
    /// In this mode, pagination must also go through `/search` (not `/browse`).
    private var recommendedUsesSearchFallback: Bool = false
    /// True when a non-nil auth token has been set via updateAuthToken(_:).
    /// Used to select between the authenticated YouTube endpoints and the local RSS feed path.
    private var hasAuthToken: Bool = false
    /// Latest requested auth state. The revision makes overlapping async token
    /// propagation latest-value-wins during fast refresh/sign-out transitions.
    private var currentAuthToken: String?
    /// Distinguishes the first explicit anonymous auth state (`nil`) from a
    /// repeated no-op update. This lets one shared Home model bootstrap exactly
    /// once for signed-in and signed-out viewers alike.
    private var hasAppliedAuthState = false
    private var authUpdateRevision: UInt = 0
    private var hideObserverTokens: [NSObjectProtocol] = []
    /// Synchronous protection against a watched video being appended by an
    /// in-flight continuation after the playback notification already removed it.
    private var suppressedDiscoveryVideoIDs: Set<String> = []

    public init(
        api: any InnerTubeAPIProtocol = InnerTubeAPI(),
        initialSection: BrowseSection? = nil,
        subscriptionMetadataCache: SubscriptionTopicMetadataCache = .shared,
        watchedVideoIDsProvider: @escaping @Sendable () async -> Set<String> = {
            RecentWatchHistoryStore.shared.watchedVideoIDSnapshot()
        }
    ) {
        self.api = api
        self.subscriptionMetadataCache = subscriptionMetadataCache
        self.watchedVideoIDsProvider = watchedVideoIDsProvider
        if let initial = initialSection {
            // Ensure the initial section appears in the picker list.
            if !sections.contains(initial) {
                sections = [initial] + sections
            }
            currentSection = initial
        }
        observeFeedHideNotifications()
    }

    isolated deinit {
        for token in hideObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Feed hide handling

    private func observeFeedHideNotifications() {
        let center = NotificationCenter.default
        hideObserverTokens.append(center.addObserver(forName: .hideVideoFromFeed, object: nil, queue: .main) { [weak self] note in
            guard let videoId = note.userInfo?["videoId"] as? String else { return }
            Task { @MainActor [weak self] in self?.removeVideo(id: videoId) }
        })
        hideObserverTokens.append(center.addObserver(forName: .hideChannelFromFeed, object: nil, queue: .main) { [weak self] note in
            guard let channelId = note.userInfo?["channelId"] as? String else { return }
            Task { @MainActor [weak self] in self?.removeChannel(id: channelId) }
        })
        hideObserverTokens.append(center.addObserver(forName: .watchHistoryDidChange, object: nil, queue: .main) { [weak self] note in
            guard let video = note.userInfo?["video"] as? Video else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.currentSection.type == .home || self.currentSection.type == .recommended
                else { return }
                self.suppressWatchedVideoFromDiscovery(id: video.id)
            }
        })
    }

    public func removeVideo(id: String) {
        for i in videoGroups.indices {
            videoGroups[i].videos.removeAll { $0.id == id }
        }
    }

    public func removeChannel(id: String) {
        for i in videoGroups.indices {
            videoGroups[i].videos.removeAll { $0.channelId == id }
        }
    }

    private func removeWatchedVideoFromDiscovery(id: String) {
        let verticalContinuation = videoGroups.last(where: { $0.nextPageToken != nil })?.nextPageToken
        for i in videoGroups.indices {
            videoGroups[i].videos.removeAll { $0.id == id }
        }
        recommendedShortsVideos.removeAll { $0.id == id }
        videoGroups.removeAll { $0.videos.isEmpty }

        // If the removed card emptied the row carrying Home's vertical token,
        // retain that token on the new last row so fresh shelves remain reachable.
        if currentSection.type == .home,
           let verticalContinuation,
           let lastIndex = videoGroups.indices.last,
           !videoGroups.contains(where: { $0.nextPageToken != nil }) {
            videoGroups[lastIndex].nextPageToken = verticalContinuation
        }
    }

    /// Internal seam used by the playback notification and deterministic unit
    /// tests. Only discovery feeds react; subscriptions and History keep their
    /// own semantics.
    func suppressWatchedVideoFromDiscovery(id: String) {
        guard currentSection.type == .home || currentSection.type == .recommended else { return }
        suppressedDiscoveryVideoIDs.insert(id)
        removeWatchedVideoFromDiscovery(id: id)
    }

    /// Immediately moves a just-started video to the top of an already-visible
    /// History feed. The subsequent server fetch will reconcile it with FEhistory.
    public func prependRecentlyWatched(_ video: Video) {
        guard currentSection.type == .history else { return }
        let historyVideo = RecentWatchHistoryEntry(video: video).video

        if videoGroups.isEmpty {
            videoGroups = [VideoGroup(title: "History", videos: [historyVideo])]
        } else {
            videoGroups[0].videos.removeAll { $0.id == historyVideo.id }
            videoGroups[0].videos.insert(historyVideo, at: 0)
        }
        isAuthRequired = false
    }

    // MARK: - Section selection

    public func select(section: BrowseSection) {
        guard section != currentSection else {
            browseLog.notice("select: already on section \(section.title) — ignored")
            return
        }
        let fromTitle = currentSection.title
        browseLog.notice("select: switching to \(section.title) from \(fromTitle)")
        currentSection = section
        loadContent(for: section, refresh: true, source: "select")
    }

    /// Reloads the given section unconditionally, bypassing the same-section guard in `select`.
    /// Use this to retry a failed/empty fetch or to recover from an observation gap.
    public func reload(section: BrowseSection) {
        browseLog.notice("reload: forcing refresh of \(section.title)")
        currentSection = section
        loadContent(
            for: section,
            refresh: true,
            source: "reload",
            subscriptionPageLimit: section.type == .subscriptions
                ? Self.initialSubscriptionSnapshotPageLimit
                : 1
        )
    }

    /// Rebuilds the visible sections list from settings.
    /// Call this when AppSettings.enabledSections changes.
    public func configureSections(_ enabledTypes: [BrowseSection.SectionType]) {
        let allSections = BrowseSection.allSections
        let ordered = enabledTypes.compactMap { type in allSections.first { $0.type == type } }
        sections = ordered.isEmpty ? BrowseSection.defaultSections : ordered
        // If current section is no longer in the list, switch to first
        if !sections.contains(currentSection), let first = sections.first {
            currentSection = first
        }
    }

    // MARK: - Loading

    public func loadContent(for section: BrowseSection? = nil, refresh: Bool = false, source: String = "unknown") {
        let target = section ?? currentSection
        loadContent(
            for: section,
            refresh: refresh,
            source: source,
            subscriptionPageLimit: target.type == .subscriptions
                ? Self.initialSubscriptionSnapshotPageLimit
                : 1
        )
    }

    func loadContent(
        for section: BrowseSection? = nil,
        refresh: Bool = false,
        source: String = "unknown",
        subscriptionPageLimit: Int
    ) {
        let target = section ?? currentSection
        let chCount = subscribedChannels.count
        let vCount = videoGroups.flatMap(\.videos).count
        let loading = isLoading
        browseLog.notice("loadContent source=\(source) section=\(target.title) refresh=\(refresh) channels=\(chCount) videos=\(vCount) loading=\(loading)")
        if refresh {
            videoGroups = []
            loadingHomeShelfIDs.removeAll()
            subscribedChannels = []
            recommendedShortsVideos = []
            loadedAt = nil
            hasCompletedInitialLoad = false
            error = nil
            isAuthRequired = false
            consecutiveEmptyShortPages = 0
            enrichTask?.cancel()
            enrichTask = nil
        }
        // UI-testing synchronous inject. For Home the IDs are split into named
        // horizontal shelves, which lets tvOS tests exercise the real focus and
        // player navigation without depending on a simulator Google session.
        if let arg = ProcessInfo.processInfo.arguments.first(where: {
               $0.hasPrefix("--uitesting-inject-recommended-ids=")
           }) {
            let raw = String(arg.dropFirst("--uitesting-inject-recommended-ids=".count))
            let ids = raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            if !ids.isEmpty, target.type == .home {
                isAuthRequired = false
                isLoading = false
                hasCompletedInitialLoad = true
                let titles = ["Recommended", "New to you", "Science & Space"]
                videoGroups = titles.map { title in
                    let videos = ids.map { id in
                        Video(
                            id: id,
                            title: "Test video \(id)",
                            channelTitle: "Test Channel"
                        )
                    }
                    return VideoGroup(title: title, videos: videos, layout: .row)
                }
                browseLog.notice("UI-testing inject: populated \(titles.count) Home shelves")
                return
            } else if !ids.isEmpty, target.type == .recommended {
                isAuthRequired = false
                recommendedUsesSearchFallback = false
                isLoading = false
                hasCompletedInitialLoad = true
                // Use .row layout (eager HStack inside ScrollView(.horizontal)) so all cards
                // are always rendered in the accessibility tree on iOS 26. LazyVGrid (.grid)
                // uses lazy rendering and its items do not appear in the XCTest accessibility tree.
                // Create 5 rows so the vertical scroll view has enough content for scroll-position
                // tests to swipe and move rows off-screen.
                videoGroups = (0..<5).map { rowIdx in
                    let rowVideos = ids.enumerated().map { i, id in
                        Video(id: rowIdx == 0 ? id : "\(id)-\(rowIdx)",
                              title: id, channelTitle: "Test Channel")
                    }
                    return VideoGroup(title: rowIdx == 0 ? "Recommended" : nil,
                                      videos: rowVideos, layout: .row)
                }
                browseLog.notice("UI-testing inject: populated \(ids.count) recommended videos synchronously")
                return
            }
        }
        contentLoadRevision &+= 1
        let revision = contentLoadRevision
        fetchTask?.cancel()
        // Publish loading synchronously. SwiftUI renders once before a newly
        // created Task gets CPU time, so setting this inside fetchSection caused
        // a one-frame "Nothing here yet" flash on every cold Home launch.
        isLoading = true
        hasCompletedInitialLoad = false
        error = nil
        fetchTask = Task {
            await fetchSection(
                target,
                revision: revision,
                subscriptionPageLimit: subscriptionPageLimit
            )
        }
    }

    public func loadMoreIfNeeded(lastVideo: Video) {
        // Use `contains` instead of `==` on the raw last video: when "Hide Shorts" is on,
        // the caller's last visible video may not be the raw last video (the raw last video
        // might be a Short that was filtered out). The user has reached the end of filtered
        // content as long as their last visible video appears anywhere in the last raw group.
        guard let lastGroup = videoGroups.last,
              lastGroup.videos.contains(where: { $0.id == lastVideo.id }),
              lastGroup.nextPageToken != nil,
              !isLoadingMore
        else {
            let hasToken = videoGroups.last?.nextPageToken != nil
            let lastVideoInGroup = videoGroups.last?.videos.contains(where: { $0.id == lastVideo.id }) == true
            print("📊 loadMoreIfNeeded SKIPPED: hasToken=\(hasToken) lastVideoInGroup=\(lastVideoInGroup) isLoadingMore=\(isLoadingMore)")
            browseLog.notice("loadMore skipped: section=\(currentSection.title) isLoading=\(isLoading) isLoadingMore=\(isLoadingMore) hasToken=\(hasToken) lastVideoMatch=\(lastVideoInGroup)")
            return
        }
        print("📊 loadMoreIfNeeded TRIGGERED: loading next page...")
        browseLog.notice("loadMore triggered: section=\(currentSection.title) currentCount=\(videoGroups.first?.videos.count ?? 0)")
        isLoadingMore = true  // synchronous guard — prevents duplicate pagination tasks before the Task body runs
        fetchTask = Task { await fetchNextPage(for: currentSection) }
    }

    /// Loads the next vertical page of personalized Home shelves when the bottom
    /// of the tvOS feed becomes visible. This must not depend on reaching the end
    /// of a horizontal carousel: vertical and horizontal continuations are
    /// independent in the YouTube TV response.
    public func loadMoreHomeRowsIfNeeded() {
        guard currentSection.type == .home,
              videoGroups.last?.nextPageToken != nil,
              !isLoading,
              !isLoadingMore
        else { return }

        browseLog.notice("Home vertical pagination triggered: shelves=\(self.videoGroups.count)")
        isLoadingMore = true
        fetchTask = Task { await fetchNextPage(for: currentSection) }
    }

    /// Loads more cards for a single horizontal Home shelf when its last card appears.
    /// This is intentionally independent from `loadMoreIfNeeded`, which adds more
    /// shelves to the bottom of the vertical Home feed.
    public func loadMoreHomeShelfIfNeeded(shelfID: UUID, lastVideo: Video) {
        guard currentSection.type == .home,
              let index = videoGroups.firstIndex(where: { $0.id == shelfID }),
              videoGroups[index].videos.contains(where: { $0.id == lastVideo.id }),
              videoGroups[index].rowContinuationToken != nil,
              !loadingHomeShelfIDs.contains(shelfID)
        else { return }

        loadingHomeShelfIDs.insert(shelfID)
        Task { await fetchNextHomeShelfPage(shelfID: shelfID) }
    }

    private func fetchNextHomeShelfPage(shelfID: UUID, autoChainDepth: Int = 0) async {
        let requestAuthRevision = authUpdateRevision
        guard let index = videoGroups.firstIndex(where: { $0.id == shelfID }),
              let token = videoGroups[index].rowContinuationToken
        else {
            loadingHomeShelfIDs.remove(shelfID)
            return
        }

        do {
            var page = try await retryWithBackoff(label: "BrowseVM[Home shelf]") {
                try await api.fetchHomeShelf(continuationToken: token)
            }
            let exclusionIDs = await discoveryExclusionIDs()
            page.videos = page.videos.filter {
                Self.isEligibleDiscoveryVideo($0, excluding: exclusionIDs)
            }
            guard requestAuthRevision == authUpdateRevision,
                  let currentIndex = videoGroups.firstIndex(where: { $0.id == shelfID }) else {
                loadingHomeShelfIDs.remove(shelfID)
                return
            }

            var seen = Set(videoGroups[currentIndex].videos.map(\.id))
            let newVideos = page.videos.filter { seen.insert($0.id).inserted }
            videoGroups[currentIndex].videos.append(contentsOf: newVideos)
            videoGroups[currentIndex].rowContinuationToken = page.nextPageToken

            browseLog.notice("Home shelf page success: title=\(self.videoGroups[currentIndex].title ?? "?") added=\(newVideos.count) nextToken=\(page.nextPageToken != nil)")

            // A continuation page can contain only duplicates. Follow a small,
            // bounded number of additional tokens so the carousel does not stall.
            if newVideos.isEmpty, page.nextPageToken != nil, autoChainDepth < 2 {
                await fetchNextHomeShelfPage(shelfID: shelfID, autoChainDepth: autoChainDepth + 1)
                return
            }
        } catch {
            if requestAuthRevision == authUpdateRevision, !Task.isCancelled {
                browseLog.error("Home shelf page failed: \(String(describing: error))")
                self.error = error
            }
        }

        loadingHomeShelfIDs.remove(shelfID)
    }

    /// Refreshes the current section's feed if the last successful fetch was more than
    /// `threshold` seconds ago (default 15 min). No-op while a fetch is already in flight.
    public func refreshIfStale(threshold: TimeInterval = 15 * 60) {
        guard !isLoading else { return }
        let age = loadedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > threshold else { return }
        let ageDesc = age.isFinite ? "\(Int(age))s" : "never loaded"
        browseLog.notice("refreshIfStale: age=\(ageDesc) > threshold=\(Int(threshold))s — refreshing \(currentSection.title)")
        loadContent(refresh: true, source: "refreshIfStale")
    }

    /// Update whether history is enabled. If currently on the history section, reloads it.
    public func updateHistoryEnabled(_ enabled: Bool) {
        guard historyEnabled != enabled else { return }
        historyEnabled = enabled
        if currentSection.type == .history {
            loadContent(refresh: true, source: "updateHistoryEnabled")
        }
    }

    // MARK: - Auth

    /// Triggers a content reload when auth state changes.
    /// Sets the token on the API first so that the fetch always runs authenticated.
    public func updateAuthToken(_ token: String?) async {
        let effectiveToken = token.flatMap { $0.isEmpty ? nil : $0 }
        if hasAppliedAuthState, currentAuthToken == effectiveToken {
            browseLog.debug("updateAuthToken: unchanged auth state — keeping current feed")
            return
        }

        hasAppliedAuthState = true
        authUpdateRevision &+= 1
        let revision = authUpdateRevision
        let wasAuthenticated = hasAuthToken
        currentAuthToken = effectiveToken
        hasAuthToken = effectiveToken != nil
        let homeAuthModeChanged = wasAuthenticated != hasAuthToken && currentSection.type == .home
        if homeAuthModeChanged {
            // Do not leave personalized shelves visible while the anonymous
            // request is being prepared after sign-out (or vice versa).
            contentLoadRevision &+= 1
            fetchTask?.cancel()
            videoGroups = []
            loadingHomeShelfIDs.removeAll()
            loadedAt = nil
            hasCompletedInitialLoad = false
            error = nil
            isAuthRequired = false
        }
        await api.setAuthToken(effectiveToken)
        guard authUpdateRevision == revision else {
            // An older update reached the API after a newer one. Repair it to
            // the latest state and never launch a stale feed request.
            await api.setAuthToken(currentAuthToken)
            return
        }
        if effectiveToken != nil {
            // Signed in — reload everything
            loadContent(refresh: true, source: "updateAuthToken")
        } else if wasAuthenticated {
            // Signed out — Home must switch from personalized shelves to public
            // discovery; account sections switch to their local/guest states.
            let authSections: Set<BrowseSection.SectionType> = [.home, .subscriptions, .channels]
            if authSections.contains(currentSection.type) {
                loadContent(refresh: true, source: "updateAuthToken.signOut")
            }
        } else if currentSection.type == .home {
            // First explicit anonymous state: bootstrap the public discovery Home.
            // Repeated nil updates return through the idempotency guard above.
            loadContent(refresh: true, source: "updateAuthToken.guestBootstrap")
        }
    }

    // MARK: - Private fetching

    private static var fetchTimeoutSeconds: TimeInterval {
        ProcessInfo.processInfo.arguments.contains("--uitesting-extended-fetch-timeout") ? 60 : 20
    }

    private func fetchSection(
        _ section: BrowseSection,
        revision: UInt,
        subscriptionPageLimit: Int
    ) async {
        defer {
            if contentLoadRevision == revision {
                isLoading = false
                hasCompletedInitialLoad = true
            }
        }
        browseLog.notice("Fetching section: \(section.title) (\(String(describing: section.type)))")
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.fetchSectionBody(
                        section,
                        subscriptionPageLimit: subscriptionPageLimit
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(Self.fetchTimeoutSeconds))
                    throw BrowseError.timeout
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            if contentLoadRevision == revision, !Task.isCancelled {
                let authSections: Set<BrowseSection.SectionType> = [.subscriptions, .history, .playlists, .channels]
                if let apiErr = error as? APIError,
                   case .httpError(let code) = apiErr,
                   (code == 401 || code == 403),
                   authSections.contains(section.type) {
                    isAuthRequired = true
                    browseLog.notice("Auth required for \(section.title) (HTTP \(code))")
                } else {
                    isAuthRequired = false
                    if case BrowseError.timeout = error {
                        browseLog.error("⏱ \(section.title) timed out after \(Int(Self.fetchTimeoutSeconds))s")
                    } else {
                        browseLog.error("❌ \(section.title) error: \(String(describing: error))")
                    }
                    self.error = error
                }
            }
        }
    }

    private func fetchSectionBody(
        _ section: BrowseSection,
        subscriptionPageLimit: Int
    ) async throws {
        switch section.type {

            case .home:
                let rows = hasAuthToken
                    ? try await api.fetchHomeRows()
                    : try await api.fetchGuestHomeRows()
                if !Task.isCancelled {
                    // 🔍 DIAGNOSTIC: Log raw data from YouTube API (stdout for devicectl)
                    print("📊 DIAGNOSTIC: FEwhat_to_watch response analysis")
                    print("📊 Total shelves received from YouTube: \(rows.count)")
                    for (index, group) in rows.enumerated() {
                        let shortsCount = group.videos.filter { $0.isShort }.count
                        let regularCount = group.videos.count - shortsCount
                        let title = group.title ?? "<no title>"
                        print("📊 Shelf[\(index)]: '\(title)' | total=\(group.videos.count) | shorts=\(shortsCount) | regular=\(regularCount) | layout=\(String(describing: group.layout))")
                    }

                    let verticalContinuation = rows.last(where: { $0.nextPageToken != nil })?.nextPageToken
                    let exclusionIDs = await discoveryExclusionIDs()
                    guard !Task.isCancelled else { return }
                    let dedupedRows = deduplicatedHomeRows(rows)
                    let unwatchedRows = Self.removingWatchedDiscoveryVideos(
                        from: dedupedRows,
                        excluding: exclusionIDs
                    )
                    var visibleRows = hasAuthToken
                        ? unwatchedRows
                        : guestVisibleHomeRows(unwatchedRows)

                    // Filtering can remove the raw final shelf that carried the
                    // vertical continuation. Move it to the final visible shelf.
                    if let verticalContinuation,
                       let lastIndex = visibleRows.indices.last,
                       !visibleRows.contains(where: { $0.nextPageToken != nil }) {
                        visibleRows[lastIndex].nextPageToken = verticalContinuation
                    }

                    if visibleRows.flatMap({ $0.videos }).isEmpty {
                        if hasAuthToken {
                            // A signed-in account can still have an empty Home
                            // (for example, with watch history disabled). Keep the
                            // existing single-feed recovery for that edge case.
                            isAuthRequired = false
                            let popular = try await api.search(query: "popular")
                            guard !Task.isCancelled else { return }
                            var deduped = popular
                            deduped.videos = deduplicated(popular.videos)
                                .filter { Self.isEligibleDiscoveryVideo($0, excluding: exclusionIDs) }
                            videoGroups = deduped.videos.isEmpty ? [] : [deduped]
                        } else {
                            // A successful transport with no usable public videos is
                            // still an unavailable guest feed. Surface retry UI instead
                            // of silently returning to the old empty-screen behaviour.
                            isAuthRequired = false
                            throw APIError.unavailable("Public videos are temporarily unavailable. Please try again.")
                        }
                    } else {
                        isAuthRequired = false
                        #if DEBUG
                        // Diagnostic counts deliberately omit continuation values.
                        print("📊 After guest/auth filtering: \(visibleRows.count) shelves")
                        for (index, group) in visibleRows.enumerated() {
                            let shortsCount = group.videos.filter { $0.isShort }.count
                            let regularCount = group.videos.count - shortsCount
                            let title = group.title ?? "<no title>"
                            print("📊 Deduped[\(index)]: '\(title)' | total=\(group.videos.count) | shorts=\(shortsCount) | regular=\(regularCount)")
                            if group.nextPageToken != nil {
                                print("📊   - nextPageToken: PRESENT")
                            }
                            if group.rowContinuationToken != nil {
                                print("📊   - rowContinuationToken: PRESENT")
                            }
                        }
                        #endif

                        videoGroups = visibleRows
                    }
                }

            case .recommended:
                // UI-testing injection: bypass the network fetch when
                // `--uitesting-inject-recommended-ids=<id1,id2,...>` is present.
                // Allows Recommended chip tests to run on unauthenticated parallel
                // simulator clones without auth or visitor-session dependency.
                if let arg = ProcessInfo.processInfo.arguments.first(where: {
                    $0.hasPrefix("--uitesting-inject-recommended-ids=")
                }) {
                    let raw = String(arg.dropFirst("--uitesting-inject-recommended-ids=".count))
                    let ids = raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
                    guard !ids.isEmpty, !Task.isCancelled else { break }
                    let videos = ids.map { Video(id: $0, title: $0, channelTitle: "Test Channel") }
                    isAuthRequired = false
                    recommendedUsesSearchFallback = false
                    videoGroups = [VideoGroup(title: "Recommended", videos: videos)]
                    break
                }
                let group = try await api.fetchHome()
                // Fetch Shorts in parallel: dedicated search + subs feed.
                // FEshorts browseId is deprecated (HTTP 400). The subs TV-browse
                // (tileRenderer, ustreamerConfig "GgIIBQ==") is the most reliable
                // source of many Shorts — mirrors HomeViewModel.homeShortsVideos.
                async let shortsFetch: VideoGroup? = try? api.fetchShorts()
                async let subsFetch: VideoGroup? = try? api.fetchSubscriptions()
                let (shortsGroup, subsGroup) = await (shortsFetch, subsFetch)
                if !Task.isCancelled {
                    let exclusionIDs = await discoveryExclusionIDs()
                    guard !Task.isCancelled else { return }
                    let searchShorts = shortsGroup?.videos ?? []
                    let subsShorts   = (subsGroup?.videos ?? []).filter { $0.isShort }
                    let homeShorts   = group.videos.filter { $0.isShort }
                    var seen = Set<String>()
                    recommendedShortsVideos = (searchShorts + subsShorts + homeShorts)
                        .filter { seen.insert($0.id).inserted }
                        .filter { Self.isEligibleDiscoveryVideo($0, excluding: exclusionIDs) }
                    browseLog.notice("Recommended: \(recommendedShortsVideos.count) shorts (search=\(searchShorts.count) subs=\(subsShorts.count) home=\(homeShorts.count))")
                    if group.videos.isEmpty {
                        isAuthRequired = true
                        recommendedUsesSearchFallback = true
                        let popular = try await api.search(query: "popular")
                        guard !Task.isCancelled else { return }
                        browseLog.notice("Recommended: home feed empty, using search fallback (nextToken=\(popular.nextPageToken != nil))")
                        var deduped = popular
                        deduped.videos = deduplicated(popular.videos)
                            .filter { Self.isEligibleDiscoveryVideo($0, excluding: exclusionIDs) }
                        videoGroups = deduped.videos.isEmpty ? [] : [deduped]
                    } else {
                        isAuthRequired = false
                        recommendedUsesSearchFallback = false
                        var deduped = group
                        deduped.videos = deduplicated(group.videos)
                            .filter { Self.isEligibleDiscoveryVideo($0, excluding: exclusionIDs) }
                        videoGroups = deduped.videos.isEmpty ? [] : [deduped]
                    }
                }

            case .subscriptions:
                if hasAuthToken {
                    let group = try await fetchSubscriptionSnapshot(
                        maxPages: subscriptionPageLimit
                    )
                    if !Task.isCancelled {
                        isAuthRequired = group.videos.isEmpty
                        videoGroups = group.videos.isEmpty ? [] : [group]
                    }
                } else {
                    let videos = await LocalSubscriptionFeedService.shared.fetchFeed(api: api)
                    if !Task.isCancelled {
                        isAuthRequired = false
                        let deduped = deduplicated(videos)
                            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
                        videoGroups = deduped.isEmpty ? [] : [VideoGroup(title: "Subscriptions", videos: deduped)]
                    }
                }

            case .history:
                guard historyEnabled else {
                    if !Task.isCancelled { videoGroups = []; isAuthRequired = false }
                    return
                }
                // Show local playback starts immediately. YouTube's FEhistory is
                // eventually consistent and can lag behind a successful stats ping.
                let initialRecent = await RecentWatchHistoryStore.shared.all
                if !Task.isCancelled, !initialRecent.isEmpty {
                    videoGroups = [VideoGroup(
                        title: "History",
                        videos: initialRecent.map(\.video)
                    )]
                    isAuthRequired = false
                }

                var group = try await api.fetchHistory()
                // Re-read after the network request so a video started while the
                // request was in flight cannot be overwritten by the older response.
                let latestRecent = await RecentWatchHistoryStore.shared.all
                let remoteIDs = Set(group.videos.map(\.id))
                group.videos = Self.mergeHistory(
                    recent: latestRecent,
                    remote: group.videos
                )
                // Do not let reconciled local entries permanently override YouTube's
                // cross-device ordering on future loads.
                await RecentWatchHistoryStore.shared.remove(videoIDs: remoteIDs)
                if !Task.isCancelled {
                    isAuthRequired = group.videos.isEmpty
                    videoGroups = group.videos.isEmpty ? [] : [group]
                }

            case .playlists:
                let playlists = try await api.fetchUserPlaylists()
                if !Task.isCancelled {
                    isAuthRequired = playlists.isEmpty
                    // Convert PlaylistInfo list into a VideoGroup of placeholder videos
                    let videos = playlists.map { pl -> Video in
                        Video(id: pl.id, title: pl.title, channelTitle: pl.videoCount.map { "\($0) videos" } ?? "",
                              thumbnailURL: pl.thumbnailURL, playlistId: pl.id)
                    }
                    videoGroups = videos.isEmpty ? [] : [VideoGroup(title: "Playlists", videos: videos)]
                }

            case .channels:
                if hasAuthToken {
                    let channels = try await api.fetchSubscribedChannels()
                    browseLog.notice("channels fetch complete: \(channels.count) channels, isCancelled=\(Task.isCancelled)")
                    if !Task.isCancelled {
                        isAuthRequired = channels.isEmpty
                        subscribedChannels = channels
                        videoGroups = []
                        let chCount = subscribedChannels.count
                        let authReq = isAuthRequired
                        browseLog.notice("channels state set: subscribedChannels=\(chCount) isAuthRequired=\(authReq)")
                        // Background-enrich avatars — the guide/params approaches yield no thumbnails;
                        // fetch each channel's About tab concurrently to get the avatar URL.
                        if !channels.isEmpty {
                            enrichTask?.cancel()
                            enrichTask = Task { await self.enrichChannelAvatars() }
                        }
                    }
                } else {
                    let localChannels = await LocalSubscriptionStore.shared.allChannelsSortedBySubscriptionDate()
                    browseLog.notice("channels (local): \(localChannels.count) followed channels sorted by subscription date, isCancelled=\(Task.isCancelled)")
                    if !Task.isCancelled {
                        isAuthRequired = false
                        subscribedChannels = localChannels.map { $0.toChannel() }
                        videoGroups = []
                    }
                }

            case .shorts:
                let group = try await api.fetchShorts()
                if !Task.isCancelled { videoGroups = group.videos.isEmpty ? [] : [group] }

            case .music:
                let group = try await api.fetchMusic()
                if !Task.isCancelled { videoGroups = [group] }

            case .gaming:
                let group = try await api.fetchGaming()
                if !Task.isCancelled { videoGroups = [group] }

            case .news:
                let group = try await api.fetchNews()
                if !Task.isCancelled { videoGroups = [group] }

            case .live:
                let group = try await api.fetchLive()
                if !Task.isCancelled { videoGroups = [group] }

            case .sports:
                let group = try await api.fetchSports()
                if !Task.isCancelled { videoGroups = [group] }

            case .settings:
                break
            }
            if !Task.isCancelled { loadedAt = Date() }
    }

    /// Builds one immutable newest-first window for the subscriptions feed.
    /// Continuation pages stay local until the window is complete, so Refresh
    /// replaces the old snapshot once instead of moving rows after every page.
    private func fetchSubscriptionSnapshot(maxPages: Int) async throws -> VideoGroup {
        let pageLimit = max(1, maxPages)
        var result = try await retryWithBackoff(label: "BrowseVM[Subscriptions refresh]") {
            try await api.fetchSubscriptions(continuationToken: nil)
        }
        try Task.checkCancellation()

        var collectedVideos = result.videos
        var continuation = result.nextPageToken
        var consumedTokens: Set<String> = []
        var fetchedPageCount = 1

        while fetchedPageCount < pageLimit,
              let token = continuation,
              consumedTokens.insert(token).inserted {
            do {
                let page = try await retryWithBackoff(label: "BrowseVM[Subscriptions refresh]") {
                    try await api.fetchSubscriptions(continuationToken: token)
                }
                try Task.checkCancellation()
                collectedVideos.append(contentsOf: page.videos)
                fetchedPageCount += 1

                // Never expose an already-consumed token to scroll pagination;
                // a malformed repeated token would otherwise loop forever.
                continuation = page.nextPageToken.flatMap {
                    consumedTokens.contains($0) ? nil : $0
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The first page is already usable. Publish that partial fresh
                // snapshot and leave the failed token for an ordinary scroll
                // pagination retry instead of blanking the screen.
                browseLog.error(
                    "Subscriptions continuation refresh failed at page \(fetchedPageCount + 1): \(String(describing: error))"
                )
                continuation = token
                break
            }
        }

        let uniqueVideos = deduplicated(collectedVideos)
        let dateEnrichedVideos = await enrichSubscriptionPublishedDates(in: uniqueVideos)
        try Task.checkCancellation()
        result.videos = stableNewestFirst(dateEnrichedVideos)
        result.nextPageToken = continuation
        return result
    }

    /// Resolves exact timestamps before publishing the replacement snapshot.
    /// Sorting the coarse InnerTube response first could place a known
    /// two-week-old upload above a fresh card whose renderer omitted its date.
    private func enrichSubscriptionPublishedDates(in videos: [Video]) async -> [Video] {
        let videoIDs = videos.map(\.id).filter { !$0.isEmpty }
        guard !videoIDs.isEmpty else { return videos }

        var metadataByVideoID = await subscriptionMetadataCache.metadata(
            for: videoIDs
        )
        let missingExactDateIDs = videoIDs.filter {
            metadataByVideoID[$0]?.publishedAt == nil
        }

        if !missingExactDateIDs.isEmpty {
            do {
                let fetched = try await api.fetchVideoTopicMetadata(
                    videoIDs: missingExactDateIDs
                )
                try Task.checkCancellation()
                await subscriptionMetadataCache.store(fetched)
                metadataByVideoID.merge(fetched) { _, newest in newest }
            } catch is CancellationError {
                return videos
            } catch {
                // The coarse renderer date remains a usable fallback. A Data
                // API outage must not turn the subscriptions page into an error.
                browseLog.error(
                    "Subscriptions exact-date enrichment failed: \(String(describing: error))"
                )
            }
        }

        return videos.map { video in
            guard let exactDate = metadataByVideoID[video.id]?.publishedAt else {
                return video
            }
            var enriched = video
            enriched.publishedAt = exactDate
            enriched.exactPublishedAt = exactDate
            return enriched
        }
    }

    /// Sorts coarse YouTube relative dates without scrambling equal-date cards.
    /// The original server offset is the deterministic tiebreaker.
    private func stableNewestFirst(_ videos: [Video]) -> [Video] {
        videos.enumerated().sorted { lhs, rhs in
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

    /// Only locally observed videos still missing from FEhistory are prepended.
    /// Once YouTube returns a video, the server's cross-device order wins.
    static func mergeHistory(
        recent: [RecentWatchHistoryEntry],
        remote: [Video]
    ) -> [Video] {
        let remoteIDs = Set(remote.map(\.id))
        var pendingIDs = Set<String>()
        let pending = recent.compactMap { entry -> Video? in
            guard !remoteIDs.contains(entry.video.id),
                  pendingIDs.insert(entry.video.id).inserted
            else { return nil }
            return entry.video
        }
        return pending + remote
    }

    /// Combines the durable on-device watch index with notifications already
    /// observed by this model. The latter closes the small race where a network
    /// continuation and playback-start event complete at nearly the same time.
    private func discoveryExclusionIDs() async -> Set<String> {
        let persisted = await watchedVideoIDsProvider()
        return persisted.union(suppressedDiscoveryVideoIDs)
    }

    /// Home is the discovery surface; History is the resume/watch-again surface.
    /// Locally observed playback is authoritative immediately. For cross-device
    /// results, a near-complete progress overlay is also enough to suppress a card.
    private static func isEligibleDiscoveryVideo(
        _ video: Video,
        excluding watchedVideoIDs: Set<String>
    ) -> Bool {
        !watchedVideoIDs.contains(video.id) && (video.watchProgress ?? 0) < 0.9
    }

    private static func removingWatchedDiscoveryVideos(
        from rows: [VideoGroup],
        excluding watchedVideoIDs: Set<String>
    ) -> [VideoGroup] {
        rows.compactMap { row in
            var copy = row
            copy.videos = row.videos.filter {
                isEligibleDiscoveryVideo($0, excluding: watchedVideoIDs)
            }
            return copy.videos.isEmpty ? nil : copy
        }
    }

    private func fetchNextPage(for section: BrowseSection, autoChainDepth: Int = 0) async {
        guard let token = videoGroups.last?.nextPageToken else {
            browseLog.notice("fetchNextPage: no token for section=\(section.title) — skipping")
            return
        }
        browseLog.notice("fetchNextPage start: section=\(section.title) continuation=present")
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            switch section.type {
            case .home:
                let newRows = try await retryWithBackoff(label: "BrowseVM[\(section.title)]") {
                    try await api.fetchHomeRows(continuationToken: token)
                }
                if Task.isCancelled {
                    browseLog.notice("fetchNextPage cancelled: section=\(section.title)")
                } else {
                    let nextPageToken = newRows.last(where: { $0.nextPageToken != nil })?.nextPageToken
                    let existingIDs = Set(videoGroups.flatMap(\.videos).map(\.id))
                    let exclusionIDs = await discoveryExclusionIDs()
                    guard !Task.isCancelled else {
                        browseLog.notice("fetchNextPage cancelled: section=\(section.title)")
                        return
                    }
                    var filteredRows = Self.removingWatchedDiscoveryVideos(
                        from: deduplicatedHomeRows(newRows, excluding: existingIDs),
                        excluding: exclusionIDs
                    )

                    // The parser attaches the vertical continuation to the last raw
                    // row. Deduplication can remove that row, so explicitly move the
                    // token to the last row that will actually be retained. The old
                    // token has already been consumed and must never remain attached
                    // to the previous page.
                    if let lastIndex = videoGroups.indices.last {
                        videoGroups[lastIndex].nextPageToken = nil
                    }
                    if !filteredRows.isEmpty {
                        filteredRows[filteredRows.count - 1].nextPageToken = nextPageToken
                    }

                    let count = filteredRows.flatMap(\.videos).count
                    browseLog.notice("fetchNextPage success: section=\(section.title) newVideos=\(count) nextToken=\(nextPageToken != nil)")
                    videoGroups.append(contentsOf: filteredRows)

                    if filteredRows.isEmpty, let nextPageToken {
                        // A page made entirely of duplicates should not terminate the
                        // vertical feed. Advance through a small bounded number of such
                        // pages so the bottom sentinel can reach fresh shelves.
                        if let lastIndex = videoGroups.indices.last {
                            videoGroups[lastIndex].nextPageToken = nextPageToken == token ? nil : nextPageToken
                        }
                        if nextPageToken != token, autoChainDepth < 3 {
                            await fetchNextPage(for: section, autoChainDepth: autoChainDepth + 1)
                        }
                    }
                }
            case .recommended:
                if recommendedUsesSearchFallback {
                    browseLog.notice("fetchNextPage: Recommended using search fallback path")
                    var group = try await retryWithBackoff(label: "BrowseVM[\(section.title)]") {
                        try await api.search(query: "popular", continuationToken: token, filter: .default)
                    }
                    if Task.isCancelled {
                        browseLog.notice("fetchNextPage cancelled: section=\(section.title)")
                    } else {
                        let exclusionIDs = await discoveryExclusionIDs()
                        guard !Task.isCancelled else {
                            browseLog.notice("fetchNextPage cancelled: section=\(section.title)")
                            return
                        }
                        group.videos = group.videos.filter {
                            Self.isEligibleDiscoveryVideo($0, excluding: exclusionIDs)
                        }
                        browseLog.notice("fetchNextPage success (search fallback): section=\(section.title) newVideos=\(group.videos.count) nextToken=\(group.nextPageToken != nil)")
                        mergeIntoFirstGroup(group)
                    }
                } else {
                    var group = try await retryWithBackoff(label: "BrowseVM[\(section.title)]") {
                        try await api.fetchHome(continuationToken: token)
                    }
                    if Task.isCancelled {
                        browseLog.notice("fetchNextPage cancelled: section=\(section.title)")
                    } else {
                        let exclusionIDs = await discoveryExclusionIDs()
                        guard !Task.isCancelled else {
                            browseLog.notice("fetchNextPage cancelled: section=\(section.title)")
                            return
                        }
                        group.videos = group.videos.filter {
                            Self.isEligibleDiscoveryVideo($0, excluding: exclusionIDs)
                        }
                        browseLog.notice("fetchNextPage success: section=\(section.title) newVideos=\(group.videos.count) nextToken=\(group.nextPageToken != nil)")
                        mergeIntoFirstGroup(group)
                    }
                }
            case .subscriptions:
                let group = try await retryWithBackoff(label: "BrowseVM[\(section.title)]") {
                    try await api.fetchSubscriptions(continuationToken: token)
                }
                if Task.isCancelled {
                    browseLog.notice("fetchNextPage cancelled: section=\(section.title)")
                } else {
                    browseLog.notice("fetchNextPage success: section=\(section.title) newVideos=\(group.videos.count) nextToken=\(group.nextPageToken != nil)")
                    // Append new videos at the bottom without re-sorting. Re-sorting the
                    // already-rendered feed after every page reorders visible rows mid-scroll,
                    // which is jarring. The initial load (loadContent) sorts once before
                    // anything is on screen; subsequent pages are simply appended in the
                    // order the API returns them.
                    mergeIntoFirstGroup(group)
                }
            case .history:
                let group = try await retryWithBackoff(label: "BrowseVM[\(section.title)]") {
                    try await api.fetchHistory(continuationToken: token)
                }
                if Task.isCancelled {
                    browseLog.notice("fetchNextPage cancelled: section=\(section.title)")
                } else {
                    browseLog.notice("fetchNextPage success: section=\(section.title) newVideos=\(group.videos.count) nextToken=\(group.nextPageToken != nil)")
                    mergeIntoFirstGroup(group)
                    // Auto-chain: when every video on this page is a Short, the view's
                    // .onAppear sentinel won't re-fire (the visible filtered list doesn't
                    // grow). Immediately fetch the next page so history keeps loading.
                    if autoChainDepth < 5,
                       group.videos.allSatisfy(\.isShort),
                       group.nextPageToken != nil {
                        browseLog.notice("fetchNextPage auto-chain (all-Shorts page): section=\(section.title) depth=\(autoChainDepth)")
                        await fetchNextPage(for: section, autoChainDepth: autoChainDepth + 1)
                    }
                }
            case .channels:
                break  // channel list doesn't paginate via videoGroups
            case .shorts:
                let group = try await retryWithBackoff(label: "BrowseVM[\(section.title)]") {
                    try await api.fetchShortsMore(continuationToken: token)
                }
                if Task.isCancelled {
                    browseLog.notice("fetchNextPage cancelled: section=\(section.title)")
                } else {
                    let before = videoGroups.first?.videos.count ?? 0
                    mergeIntoFirstGroup(group)
                    let after = videoGroups.first?.videos.count ?? 0
                    let added = after - before
                    browseLog.notice("fetchNextPage success: section=\(section.title) newVideos=\(added) nextToken=\(group.nextPageToken != nil)")
                    if added == 0 {
                        consecutiveEmptyShortPages += 1
                        browseLog.notice("fetchNextPage: Shorts empty page #\(consecutiveEmptyShortPages)")
                        if consecutiveEmptyShortPages >= 3 {
                            // API is cycling through already-seen or empty results.
                            // Clear the token so the scroll-trigger sentinel stops looping.
                            browseLog.notice("fetchNextPage: clearing Shorts token after \(consecutiveEmptyShortPages) consecutive empty pages")
                            videoGroups[0].nextPageToken = nil
                            consecutiveEmptyShortPages = 0
                        }
                    } else {
                        consecutiveEmptyShortPages = 0
                    }
                }
            case .music:
                let group = try await retryWithBackoff(label: "BrowseVM[\(section.title)]") {
                    try await api.fetchMusic()
                }
                if Task.isCancelled {
                    browseLog.notice("fetchNextPage cancelled: section=\(section.title)")
                } else {
                    browseLog.notice("fetchNextPage success: section=\(section.title) newVideos=\(group.videos.count) nextToken=\(group.nextPageToken != nil)")
                    mergeIntoFirstGroup(group)
                }
            case .gaming:
                let group = try await retryWithBackoff(label: "BrowseVM[\(section.title)]") {
                    try await api.fetchGaming()
                }
                if Task.isCancelled {
                    browseLog.notice("fetchNextPage cancelled: section=\(section.title)")
                } else {
                    browseLog.notice("fetchNextPage success: section=\(section.title) newVideos=\(group.videos.count) nextToken=\(group.nextPageToken != nil)")
                    mergeIntoFirstGroup(group)
                }
            case .news:
                let group = try await retryWithBackoff(label: "BrowseVM[\(section.title)]") {
                    try await api.fetchNews()
                }
                if Task.isCancelled {
                    browseLog.notice("fetchNextPage cancelled: section=\(section.title)")
                } else {
                    browseLog.notice("fetchNextPage success: section=\(section.title) newVideos=\(group.videos.count) nextToken=\(group.nextPageToken != nil)")
                    mergeIntoFirstGroup(group)
                }
            case .live:
                let group = try await retryWithBackoff(label: "BrowseVM[\(section.title)]") {
                    try await api.fetchLive()
                }
                if Task.isCancelled {
                    browseLog.notice("fetchNextPage cancelled: section=\(section.title)")
                } else {
                    browseLog.notice("fetchNextPage success: section=\(section.title) newVideos=\(group.videos.count) nextToken=\(group.nextPageToken != nil)")
                    mergeIntoFirstGroup(group)
                }
            case .sports:
                let group = try await retryWithBackoff(label: "BrowseVM[\(section.title)]") {
                    try await api.fetchSports()
                }
                if Task.isCancelled {
                    browseLog.notice("fetchNextPage cancelled: section=\(section.title)")
                } else {
                    browseLog.notice("fetchNextPage success: section=\(section.title) newVideos=\(group.videos.count) nextToken=\(group.nextPageToken != nil)")
                    mergeIntoFirstGroup(group)
                }
            default:
                break
            }
        } catch {
            if !Task.isCancelled {
                browseLog.error("fetchNextPage failed: section=\(section.title) error=\(String(describing: error))")
                self.error = error
            }
        }
    }

    /// Appends `group.videos` into `videoGroups[0]` and updates its pagination token.
    /// Falls back to inserting `group` as a new group if none exist yet.
    private func mergeIntoFirstGroup(_ group: VideoGroup) {
        if videoGroups.isEmpty {
            videoGroups.append(group)
        } else {
            // Use a growing set so duplicate IDs within group.videos itself
            // (same video appearing twice in one page) are also caught.
            var seenIds = Set(videoGroups[0].videos.map(\.id))
            let newVideos = group.videos.filter { seenIds.insert($0.id).inserted }
            videoGroups[0].videos.append(contentsOf: newVideos)
            videoGroups[0].nextPageToken = group.nextPageToken
        }
    }

    /// Returns `videos` with duplicate IDs removed, preserving first-occurrence order.
    private func deduplicated(_ videos: [Video]) -> [Video] {
        var seen = Set<String>()
        return videos.filter { seen.insert($0.id).inserted }
    }

    /// Removes duplicates inside each shelf while preserving legitimate overlap
    /// between different Google-titled Home shelves.
    private func deduplicatedHomeRows(
        _ rows: [VideoGroup],
        excluding initialIDs: Set<String> = []
    ) -> [VideoGroup] {
        return rows.compactMap { row in
            var seen = initialIDs
            var copy = row
            copy.videos = row.videos.filter { seen.insert($0.id).inserted }
            return copy.videos.isEmpty ? nil : copy
        }
    }

    /// Removes shelves that imply account-level personalization from an
    /// anonymous Home response and strips Shorts from the living-room feed.
    private func guestVisibleHomeRows(_ rows: [VideoGroup]) -> [VideoGroup] {
        rows.compactMap { row in
            guard !Self.isGuestPersonalizedShelfTitle(row.title) else { return nil }

            var copy = row
            copy.videos = deduplicated(row.videos.filter { !$0.isShort })
            return copy.videos.isEmpty ? nil : copy
        }
    }

    /// Defensive filter for injected/legacy guest rows. Live guest rows are
    /// semantically retitled from their FEtopics_* guide destination before they
    /// reach this view model, so correctness does not depend on this translation set.
    public nonisolated static func isGuestPersonalizedShelfTitle(_ title: String?) -> Bool {
        let normalized = title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !normalized.isEmpty else { return false }

        let exactTitles: Set<String> = [
            "recommended", "recommendations", "recommended videos", "for you", "new to you", "shorts",
            "рекомендации", "рекомендуемое", "рекомендованные", "для вас", "новое для вас",
            "recomendado", "recomendados", "recomendações", "para você", "para si",
            "empfohlen", "empfehlungen", "recommandé", "recommandés", "recommandations",
            "موصى به", "الفيديوهات المقترحة", "अनुशंसित", "सुझाए गए", "आपके लिए",
            "preporučeno", "direkomendasikan", "consigliato", "consigliati",
            "おすすめ", "あなたへのおすすめ", "추천", "맞춤 동영상",
            "препоручено", "önerilen", "推荐", "推荐视频", "为你推荐",
            "aanbevolen", "voor jou", "polecane", "rekomendowane", "dla ciebie",
            "rekommenderat", "för dig", "προτεινόμενα", "για εσάς",
            "מומלץ", "בשבילך", "עבורך", "แนะนำ", "สำหรับคุณ",
            "đề xuất", "dành cho bạn", "рекомендоване", "для тебе",
            "doporučeno", "pro vás", "anbefalet", "til dig", "suositellut",
            "sinulle", "anbefalt", "for deg", "recomandate", "pentru tine",
            "ajánlott", "neked", "disyorkan", "inirerekomenda", "para sa iyo",
            "recomanats", "per a tu", "odporúčané", "pre vás",
            "препоръчано", "за вас"
        ]
        if exactTitles.contains(normalized) { return true }

        let personalizedSuffixes = [
            " for you", " new to you", " für dich", " pour vous", " para ti",
            " для вас", " आपके लिए", " za vas", " untuk anda", " per te",
            " за вас", " sizin için"
        ]
        return normalized.hasPrefix("recommended ")
            || normalized.hasPrefix("recommendation ")
            || personalizedSuffixes.contains(where: normalized.hasSuffix)
    }

    // MARK: - Channel avatar enrichment

    /// Concurrently fetches the avatar thumbnail URL for each subscribed channel and
    /// patches it into `subscribedChannels` as results arrive.
    ///
    /// The TV subscription feed only returns video tiles (no channel avatars), so we
    /// fetch each channel's About tab to get the avatar URL. Requests are fired
    /// concurrently. The task is cancelled automatically when the user leaves the
    /// Channels section (enrichTask?.cancel() in loadContent).
    private func enrichChannelAvatars() async {
        let snapshot = subscribedChannels
        guard !snapshot.isEmpty else { return }
        let missing = snapshot.filter { $0.thumbnailURL == nil }
        guard !missing.isEmpty else { return }
        browseLog.notice("enrichChannelAvatars: fetching avatars for \(missing.count) channels")

        let apiRef = api
        let indexByID: [String: Int] = Dictionary(
            uniqueKeysWithValues: snapshot.enumerated().map { ($1.id, $0) }
        )

        await withTaskGroup(of: (String, URL?).self) { group in
            for channel in missing {
                guard !Task.isCancelled else { break }
                let channelId = channel.id
                group.addTask {
                    let url = try? await apiRef.fetchChannelThumbnailURL(channelId: channelId)
                    return (channelId, url)
                }
            }
            for await (channelId, thumbURL) in group {
                guard !Task.isCancelled else { break }
                guard let thumbURL,
                      let idx = indexByID[channelId],
                      idx < self.subscribedChannels.count
                else { continue }
                self.subscribedChannels[idx].thumbnailURL = thumbURL
            }
        }

        let finalCount = self.subscribedChannels.filter { $0.thumbnailURL != nil }.count
        let total = self.subscribedChannels.count
        browseLog.notice("enrichChannelAvatars done: \(finalCount)/\(total) have avatars")
    }
}
