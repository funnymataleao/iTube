import Foundation
import Observation

// MARK: - SearchViewModel
//
// Mirrors the Android `SearchPresenter`.

@MainActor
@Observable
public final class SearchViewModel {

    public var query: String = ""
    public var filter: SearchFilter = .default
    public private(set) var results: [Video] = []
    public private(set) var history: [SearchHistoryEntry] = []
    public private(set) var isLoading: Bool = false
    public private(set) var displayedQuery: String = ""
    public var error: Error?

    private let api: any InnerTubeAPIProtocol
    private let historyStore: SearchHistoryStore
    private var nextPageToken: String?
    private var searchTask: Task<Void, Never>?
    private var activeRequestID = UUID()
    private var isPreviewing = false
    private var committedQuery: String?
    private var committedResults: [Video] = []
    private var committedNextPageToken: String?
    private var hideObserverTasks: [Task<Void, Never>] = []

    /// History entries that match the current query (case-insensitive). Returns
    /// the full history when the query is empty.
    public var filteredHistory: [SearchHistoryEntry] {
        guard !query.isEmpty else { return history }
        return history.filter { $0.query.localizedCaseInsensitiveContains(query) }
    }

    public init(api: any InnerTubeAPIProtocol = InnerTubeAPI(), historyStore: SearchHistoryStore = .shared) {
        self.api = api
        self.historyStore = historyStore
        Task { [weak self] in
            guard let self else { return }
            await self.loadHistory()
            self.restoreMostRecentSearchIfNeeded()
        }
        observeFeedHideNotifications()
    }

    /// Debounces remote-keyboard input and refreshes the video grid without
    /// polluting the user's submitted search history.
    public func updateResults(for rawQuery: String) async {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if isPreviewing {
                searchTask?.cancel()
            }
            restoreCommittedResults()
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(450))
        } catch {
            return
        }
        guard !Task.isCancelled, trimmed != displayedQuery || results.isEmpty else { return }
        startSearch(query: trimmed, isPreview: true)
    }

    public func search() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        startSearch(query: trimmed, isPreview: false)
        Task { await recordSearch(trimmed) }
    }

    // MARK: - History management

    /// Loads history from the store into the published `history` property.
    public func loadHistory() async {
        history = await historyStore.all
    }

    /// Saves `query` to history and refreshes the in-memory list.
    private func recordSearch(_ query: String) async {
        await historyStore.add(query)
        history = await historyStore.all
    }

    /// Removes a single entry from history.
    public func removeHistoryEntry(_ query: String) {
        Task {
            await historyStore.remove(query)
            history = await historyStore.all
        }
    }

    /// Clears all history entries.
    public func clearHistory() {
        Task {
            await historyStore.clear()
            history = await historyStore.all
        }
    }

    /// Apply a new filter and re-run the current search immediately.
    public func applyFilter(_ newFilter: SearchFilter) {
        filter = newFilter
        let typedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetQuery = typedQuery.isEmpty ? displayedQuery : typedQuery
        guard !targetQuery.isEmpty else { return }
        startSearch(query: targetQuery, isPreview: !typedQuery.isEmpty && isPreviewing)
    }

    public func loadMore() {
        guard let token = nextPageToken, !isLoading else { return }
        let requestID = activeRequestID
        let targetQuery = displayedQuery
        let preview = isPreviewing
        let currentFilter = filter
        searchTask = Task { [weak self] in
            await self?.performSearch(
                query: targetQuery,
                continuationToken: token,
                filter: currentFilter,
                isPreview: preview,
                requestID: requestID
            )
        }
    }

    public func retry() {
        let typedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetQuery = typedQuery.isEmpty ? displayedQuery : typedQuery
        guard !targetQuery.isEmpty else { return }
        startSearch(query: targetQuery, isPreview: !typedQuery.isEmpty && isPreviewing)
    }

    private func restoreMostRecentSearchIfNeeded() {
        guard committedQuery == nil,
              results.isEmpty,
              query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let latestQuery = history.first?.query else { return }
        startSearch(query: latestQuery, isPreview: false)
    }

    private func restoreCommittedResults() {
        guard let committedQuery else {
            if history.isEmpty {
                results = []
                displayedQuery = ""
                nextPageToken = nil
                error = nil
            }
            return
        }
        results = committedResults
        displayedQuery = committedQuery
        nextPageToken = committedNextPageToken
        isPreviewing = false
        isLoading = false
        error = nil
    }

    private func startSearch(query: String, isPreview: Bool) {
        searchTask?.cancel()
        let requestID = UUID()
        activeRequestID = requestID
        displayedQuery = query
        isPreviewing = isPreview
        results = []
        nextPageToken = nil
        error = nil
        isLoading = true
        let currentFilter = filter
        searchTask = Task { [weak self] in
            await self?.performSearch(
                query: query,
                filter: currentFilter,
                isPreview: isPreview,
                requestID: requestID
            )
        }
    }

    private func performSearch(
        query: String,
        continuationToken: String? = nil,
        filter: SearchFilter = .default,
        isPreview: Bool,
        requestID: UUID
    ) async {
        isLoading = true
        defer {
            if activeRequestID == requestID {
                isLoading = false
            }
        }
        do {
            let group = try await retryWithBackoff(label: "SearchVM") {
                try await api.search(query: query, continuationToken: continuationToken, filter: filter)
            }
            guard !Task.isCancelled, activeRequestID == requestID else { return }
            if continuationToken == nil {
                results = group.videos
            } else {
                results.append(contentsOf: group.videos)
            }
            nextPageToken = group.nextPageToken
            displayedQuery = query
            self.isPreviewing = isPreview
            if !isPreview {
                committedQuery = query
                committedResults = results
                committedNextPageToken = nextPageToken
            }
        } catch {
            if !Task.isCancelled, activeRequestID == requestID {
                self.error = error
            }
        }
    }

    // MARK: - Feed hide handling

    private func observeFeedHideNotifications() {
        hideObserverTasks.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .hideVideoFromFeed) {
                guard let self, let videoId = note.userInfo?["videoId"] as? String else { continue }
                self.results.removeAll { $0.id == videoId }
                self.committedResults.removeAll { $0.id == videoId }
            }
        })
        hideObserverTasks.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .hideChannelFromFeed) {
                guard let self, let channelId = note.userInfo?["channelId"] as? String else { continue }
                self.results.removeAll { $0.channelId == channelId }
                self.committedResults.removeAll { $0.channelId == channelId }
            }
        })
    }
}

// MARK: - ChannelViewModel

@MainActor
@Observable
public final class ChannelViewModel {

    public private(set) var channel: Channel?
    public private(set) var videos: [Video] = []
    public private(set) var isLoading: Bool = false
    public var error: Error?

    private let api: any InnerTubeAPIProtocol
    private var nextPageToken: String?
    private var hideObserverTasks: [Task<Void, Never>] = []

    public init(api: any InnerTubeAPIProtocol = InnerTubeAPI()) {
        self.api = api
        observeFeedHideNotifications()
    }

    public func load(channelId: String) {
        Task { await loadAsync(channelId: channelId) }
    }

    private func loadAsync(channelId: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let (ch, group) = try await api.fetchChannel(channelId: channelId)
            channel = ch
            videos  = group.videos
            nextPageToken = group.nextPageToken
        } catch {
            self.error = error
        }
    }

    public func loadMore() {
        guard let id = channel?.id, let token = nextPageToken, !isLoading else { return }
        Task {
            isLoading = true
            defer { isLoading = false }
            do {
                let group = try await retryWithBackoff(label: "ChannelVM") {
                    try await api.fetchChannelVideos(channelId: id, continuationToken: token)
                }
                videos.append(contentsOf: group.videos)
                nextPageToken = group.nextPageToken
            } catch {
                self.error = error
            }
        }
    }

    // MARK: - Feed hide handling

    private func observeFeedHideNotifications() {
        hideObserverTasks.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .hideVideoFromFeed) {
                guard let self, let videoId = note.userInfo?["videoId"] as? String else { continue }
                self.videos.removeAll { $0.id == videoId }
            }
        })
        hideObserverTasks.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .hideChannelFromFeed) {
                guard let self, let channelId = note.userInfo?["channelId"] as? String else { continue }
                self.videos.removeAll { $0.channelId == channelId }
            }
        })
    }
}
