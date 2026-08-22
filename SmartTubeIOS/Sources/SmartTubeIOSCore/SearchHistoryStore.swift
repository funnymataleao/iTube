import Foundation

// MARK: - SearchHistoryStore
//
// Persists the user's local search query history across sessions.
// Stores up to `maxEntries` entries, newest-first. Re-submitting an existing
// query moves it to the top rather than creating a duplicate.
//
// Thread-safe: implemented as a Swift actor, mirroring VideoStateStore,
// LocalSubscriptionStore, and CurrentQueueStore.

public actor SearchHistoryStore: UserDefaultsBackedStore {

    // MARK: - Singleton

    public static let shared = SearchHistoryStore()

    // MARK: - Private

    static let defaultsKey = "st_search_history"
    private static let maxEntries = 50

    private var entries: [SearchHistoryEntry] = []
    let defaults: UserDefaults

    private init() {
        self.defaults = .standard
        if let loaded = Self.loadFrom(.standard) { entries = loaded }
    }

    /// Designated initializer for unit testing. Pass a unique `suiteName` string
    /// (e.g. `"test-\(UUID().uuidString)"`) to get a fully isolated store with
    /// no shared `UserDefaults` state.
    init(suiteName: String) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        if let loaded = Self.loadFrom(self.defaults) { entries = loaded }
    }

    // MARK: - Public API

    /// All history entries sorted newest-first.
    public var all: [SearchHistoryEntry] { entries }

    /// Adds or updates `query` in the history.
    /// If the query already exists it is moved to the top; otherwise a new entry
    /// is prepended. Trims to `maxEntries` by dropping the oldest entry when needed.
    public func add(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let existingPreview = entries.first {
            $0.query.caseInsensitiveCompare(trimmed) == .orderedSame
        }?.previewVideoIDs
        entries.removeAll { $0.query.lowercased() == trimmed.lowercased() }
        entries.insert(
            SearchHistoryEntry(query: trimmed, previewVideoIDs: existingPreview),
            at: 0
        )
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        persist()
    }

    /// Adds artwork references to an existing query without changing its order
    /// or timestamp. Only opaque YouTube video IDs are persisted; images remain
    /// in the system URL cache and are fetched from YouTube's image CDN as needed.
    public func updatePreview(for query: String, videoIDs: [String]) {
        guard !videoIDs.isEmpty else { return }
        let uniqueIDs = videoIDs.reduce(into: [String]()) { result, id in
            guard !id.isEmpty, !result.contains(id) else { return }
            result.append(id)
        }
        guard !uniqueIDs.isEmpty else { return }

        let previews = Array(uniqueIDs.prefix(3))
        if let index = entries.firstIndex(where: {
            $0.query.caseInsensitiveCompare(query) == .orderedSame
        }) {
            let entry = entries[index]
            entries[index] = SearchHistoryEntry(
                query: entry.query,
                timestamp: entry.timestamp,
                previewVideoIDs: previews
            )
        } else {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            entries.insert(
                SearchHistoryEntry(query: trimmed, previewVideoIDs: previews),
                at: 0
            )
            if entries.count > Self.maxEntries {
                entries = Array(entries.prefix(Self.maxEntries))
            }
        }
        persist()
    }

    /// Removes the entry matching `query` (case-insensitive). No-op if not found.
    public func remove(_ query: String) {
        entries.removeAll { $0.query.lowercased() == query.lowercased() }
        persist()
    }

    /// Deletes all history entries.
    public func clear() {
        entries = []
        persist()
    }

    // MARK: - UserDefaultsBackedStore

    func encodedValue() -> [SearchHistoryEntry] { entries }
    func decodeValue(_ decoded: [SearchHistoryEntry]) { entries = decoded }
}
