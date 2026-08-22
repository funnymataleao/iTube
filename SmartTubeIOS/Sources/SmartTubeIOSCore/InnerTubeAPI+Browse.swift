import Foundation
import os
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let tubeLog = Logger(subsystem: appSubsystem, category: "InnerTube")
private let guestTVContinuationPrefix = "guest-tv:"

private struct GuestTopicDestination: Sendable {
    let index: Int
    let title: String
    let browseID: String
}

// MARK: - Browse endpoints

extension InnerTubeAPI {

    // MARK: - Visitor data helper

    /// Extracts `responseContext.visitorData` from a browse response and stores it.
    /// The stored token is included in subsequent home-feed requests so YouTube can
    /// tailor recommendations to this specific device/session.
    func updateVisitorData(from response: [String: Any]) {
        guard let ctx = response["responseContext"] as? [String: Any],
              let vd = ctx["visitorData"] as? String, !vd.isEmpty else { return }
        visitorData = vd
    }

    // MARK: - Home

    /// Applies the viewer's device language and region to anonymous discovery
    /// requests, matching the public YouTube surface more closely than the
    /// authenticated client's fixed fallback locale.
    private var localizedGuestClientContext: [String: Any] {
        var context = tvClientContext
        var client = (context["client"] as? [String: Any]) ?? [:]
        let locale = Locale.autoupdatingCurrent
        client["hl"] = locale.language.languageCode?.identifier ?? "en"
        client["gl"] = locale.region?.identifier ?? "US"
        context["client"] = client
        return context
    }

    private var localizedGuestWebClientContext: [String: Any] {
        var context = webClientContext
        var client = (context["client"] as? [String: Any]) ?? [:]
        let locale = Locale.autoupdatingCurrent
        client["hl"] = locale.language.languageCode?.identifier ?? "en"
        client["gl"] = locale.region?.identifier ?? "US"
        context["client"] = client
        return context
    }

    /// Fetches the home feed.
    /// When authenticated, uses TVHTML5 on youtubei.googleapis.com for a personalised feed.
    /// When unauthenticated, uses the WEB client on www.youtube.com for the default feed.
    public func fetchHome(continuationToken: String? = nil) async throws -> VideoGroup {
        let isAuth = authToken != nil
        var body = makeBody(client: isAuth ? tvClientContext : localizedGuestWebClientContext,
                            continuationToken: continuationToken,
                            includeVisitorData: true)
        if continuationToken == nil {
            body["browseId"] = "FEwhat_to_watch"
        }
        let data = isAuth
            ? try await postTV(endpoint: "browse", body: body)
            : try await post(endpoint: "browse", body: body)
        updateVisitorData(from: data)
        return try parseVideoGroup(from: data, title: BrowseSection.SectionType.home.defaultTitle)
    }

    /// Fetches the home feed as multiple named shelves (TYPE_ROW in Android).
    /// Returns one VideoGroup per shelf; each has layout == .row.
    /// Falls back to a single flat VideoGroup if no shelves are found.
    public func fetchHomeRows(continuationToken: String? = nil) async throws -> [VideoGroup] {
        let isAuth = authToken != nil
        print("📊 fetchHomeRows: authToken=\(authToken != nil ? "present" : "nil") client=\(isAuth ? "TVHTML5" : "WEB")")
        var body = makeBody(client: isAuth ? tvClientContext : localizedGuestWebClientContext,
                            continuationToken: continuationToken,
                            includeVisitorData: true)
        if continuationToken == nil {
            body["browseId"] = "FEwhat_to_watch"
        }
        let data = isAuth
            ? try await postTV(endpoint: "browse", body: body)
            : try await post(endpoint: "browse", body: body)
        updateVisitorData(from: data)
        let rows = parseVideoGroupRows(from: data)
        tubeLog.notice("fetchHomeRows → \(rows.count, privacy: .public) shelves")
        let rowShortsDetail = rows.map { row -> String in
            let s = row.videos.filter { $0.isShort }.count
            return "'\(row.title ?? "?")': \(s)/\(row.videos.count) shorts"
        }.joined(separator: ", ")
        tubeLog.notice("fetchHomeRows shelf detail: [\(rowShortsDetail, privacy: .public)]")
        return rows
    }

    /// Builds the signed-out Home from the public topic destinations exposed by
    /// YouTube TV's own guide. Topic and shelf order/titles remain server-owned.
    public func fetchGuestHomeRows() async throws -> [VideoGroup] {
        let client = localizedGuestClientContext
        let destinations: [GuestTopicDestination]
        do {
            let guideBody = makeBody(client: client, includeVisitorData: true)
            let guideData = try await postTVCategory(endpoint: "guide", body: guideBody)
            updateVisitorData(from: guideData)
            let parsed = parseGuestTopicDestinations(from: guideData)
            if parsed.isEmpty {
                tubeLog.notice("fetchGuestHomeRows: guide contained no FEtopics_* destinations; using known public topic IDs")
                destinations = fallbackGuestTopicDestinations
            } else {
                destinations = parsed
            }
        } catch {
            // The guide schema is not required for availability. These IDs are
            // YouTube-owned public destinations and their shelf titles still come
            // from each live response.
            tubeLog.notice("fetchGuestHomeRows guide failed; using known public topic IDs: \(error, privacy: .public)")
            destinations = fallbackGuestTopicDestinations
        }

        let result = await withTaskGroup(of: (Int, [VideoGroup], Bool).self) { group in
            for destination in destinations {
                group.addTask { [self] in
                    do {
                        let rows = try await fetchGuestTopicRows(destination)
                        return (destination.index, rows, true)
                    } catch {
                        tubeLog.notice("Guest topic \(destination.browseID, privacy: .public) failed: \(error, privacy: .public)")
                        return (destination.index, [], false)
                    }
                }
            }

            var pages: [(Int, [VideoGroup], Bool)] = []
            for await page in group where !Task.isCancelled {
                pages.append(page)
            }
            let orderedPages = pages.sorted { $0.0 < $1.0 }
            let rows = orderedPages.flatMap(\.1)
            return (
                rows: rows,
                hadUsableResponse: orderedPages.contains { page in
                    page.2 && page.1.contains { !$0.videos.isEmpty }
                }
            )
        }

        guard result.hadUsableResponse else {
            throw APIError.unavailable("Public videos are temporarily unavailable. Please try again.")
        }
        return result.rows
    }

    private var fallbackGuestTopicDestinations: [GuestTopicDestination] {
        [
            ("Music", "FEtopics_music"),
            ("Movies", "FEtopics_movies"),
            ("Live", "FEtopics_live"),
            ("Gaming", "FEtopics_gaming"),
            ("News", "FEtopics_news"),
            ("Sports", "FEtopics_sports"),
            ("Podcasts", "FEtopics_podcasts"),
        ].enumerated().map { index, item in
            GuestTopicDestination(index: index, title: item.0, browseID: item.1)
        }
    }

    private func parseGuestTopicDestinations(from guide: [String: Any]) -> [GuestTopicDestination] {
        guard let sections = guide["items"] as? [[String: Any]] else { return [] }
        var result: [GuestTopicDestination] = []
        var seen = Set<String>()

        for section in sections {
            guard let renderer = section["guideSectionRenderer"] as? [String: Any],
                  let items = renderer["items"] as? [[String: Any]]
            else { continue }

            for item in items {
                guard let entry = item["guideEntryRenderer"] as? [String: Any],
                      let endpoint = entry["navigationEndpoint"] as? [String: Any],
                      let browse = endpoint["browseEndpoint"] as? [String: Any],
                      let browseID = browse["browseId"] as? String,
                      browseID.hasPrefix("FEtopics_"),
                      !browseID.localizedCaseInsensitiveContains("shorts"),
                      seen.insert(browseID).inserted
                else { continue }

                let title = (entry["formattedTitle"] as? [String: Any]).flatMap(extractText)
                    ?? (entry["title"] as? [String: Any]).flatMap(extractText)
                    ?? ""
                result.append(GuestTopicDestination(
                    index: result.count,
                    title: title,
                    browseID: browseID
                ))
            }
        }
        return result
    }

    private func fetchGuestTopicRows(
        _ destination: GuestTopicDestination
    ) async throws -> [VideoGroup] {
        let client = localizedGuestClientContext
        var body = makeBody(client: client, includeVisitorData: true)
        body["browseId"] = destination.browseID
        let data = try await postTVCategory(endpoint: "browse", body: body)
        updateVisitorData(from: data)
        let rows = parseVideoGroupRows(from: data)

        // A topic response can contain several editorial sub-shelves, including a
        // locale-specific generic "Recommended" label. Guest Home intentionally
        // exposes one semantically named shelf per public FEtopics_* destination.
        // This keeps the surface topic-based in every locale without trying to
        // maintain an open-ended translation blacklist.
        guard var row = rows.first(where: { candidate in
            candidate.videos.contains { !$0.isShort }
        }) else { return [] }

        row.title = destination.title.isEmpty
            ? fallbackGuestTopicTitle(for: destination.browseID)
            : destination.title
        // The current Home model has one global vertical continuation, while every
        // topic owns a different one. Keep the selected shelf's independent
        // horizontal continuation and stop the topic at its first page.
        row.nextPageToken = nil
        row.rowContinuationToken = tagGuestTVContinuation(row.rowContinuationToken)
        return [row]
    }

    private func fallbackGuestTopicTitle(for browseID: String) -> String {
        browseID
            .replacingOccurrences(of: "FEtopics_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .localizedCapitalized
    }

    private func tagGuestTVContinuation(_ token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        return token.hasPrefix(guestTVContinuationPrefix)
            ? token
            : guestTVContinuationPrefix + token
    }

    private func untagGuestTVContinuation(_ token: String) -> String? {
        guard token.hasPrefix(guestTVContinuationPrefix) else { return nil }
        return String(token.dropFirst(guestTVContinuationPrefix.count))
    }

    /// Fetches the next page for one horizontal Home shelf. TVHTML5 returns
    /// these as `horizontalListContinuation`, independently from the vertical
    /// `sectionListContinuation` used by `fetchHomeRows`.
    public func fetchHomeShelf(continuationToken: String) async throws -> VideoGroup {
        let isAuth = authToken != nil
        let guestTVToken = untagGuestTVContinuation(continuationToken)
        let rawToken = guestTVToken ?? continuationToken
        // The continuation's issuing client takes precedence over a later auth
        // transition. A guest topic token remains a public TV token even if the
        // viewer signs in while its request is in flight.
        var client = guestTVToken != nil
            ? localizedGuestClientContext
            : (isAuth ? tvClientContext : localizedGuestWebClientContext)
        if guestTVToken != nil, let visitorData {
            // TVHTML5 category continuations bind visitorData to context.client;
            // the generic top-level field is ignored and returns an empty page.
            var clientFields = (client["client"] as? [String: Any]) ?? [:]
            clientFields["visitorData"] = visitorData
            client["client"] = clientFields
        }
        let body = makeBody(client: client,
                            continuationToken: rawToken,
                            includeVisitorData: true)
        // Continuation tokens are bound to the client that issued them. Public
        // FEwhat_to_watch rows come from WEB; public topic and personalized
        // shelves come from TVHTML5 through different authenticated transports.
        let data: [String: Any]
        if guestTVToken != nil {
            data = try await postTVCategory(endpoint: "browse", body: body)
        } else if isAuth {
            data = try await postTV(endpoint: "browse", body: body)
        } else {
            data = try await post(endpoint: "browse", body: body)
        }
        updateVisitorData(from: data)
        var group = try parseVideoGroup(from: data, title: nil)
        if guestTVToken != nil {
            group.nextPageToken = tagGuestTVContinuation(group.nextPageToken)
        }
        return group
    }

    // MARK: - Subscriptions

    /// Fetches subscriptions feed (requires auth).
    /// Uses TVHTML5 client on youtubei.googleapis.com — the only endpoint that accepts
    /// the OAuth token issued by the TV device-code flow.
    public func fetchSubscriptions(continuationToken: String? = nil) async throws -> VideoGroup {
        var body = makeBody(client: tvClientContext, continuationToken: continuationToken)
        if continuationToken == nil {
            body["browseId"] = "FEsubscriptions"
        }
        let data = try await postTV(endpoint: "browse", body: body)
        let group = try parseVideoGroup(from: data, title: "Subscriptions")
        // Preserve the API's arrival order — YouTube returns tiles in the order
        // it considers most relevant. Sorting by date re-inserts new pages'
        // videos between existing ones instead of appending them.
        return group
    }

    /// Fetches the list of channels the authenticated user subscribes to (requires auth).
    ///
    /// Strategy:
    ///  1. `/guide` endpoint with TV client + auth — returns the TV sidebar guide which
    ///     includes every subscribed channel with avatar thumbnail URLs via guideEntryRenderer.
    ///  2. If that yields no channels, fall back to parsing unique channels from the
    ///     TVHTML5 video-tile subscription feed (channel IDs + names, no avatars).
    public func fetchSubscribedChannels() async throws -> [Channel] {
        // Primary: TV guide sidebar — includes subscribed channels with avatar thumbnails
        let guideBody = makeBody(client: tvClientContext)
        let guideData = try await postTV(endpoint: "guide", body: guideBody)
        let guideKeys = Array(guideData.keys.sorted().prefix(8))
        tubeLog.notice("fetchSubscribedChannels guide top-level keys: \(guideKeys, privacy: .public)")
        let guideChannels = parseGuideChannels(from: guideData)
        tubeLog.notice("fetchSubscribedChannels guide → \(guideChannels.count, privacy: .public) channels")
        if !guideChannels.isEmpty { return guideChannels }

        // Fallback: TV subscription video-tile feed — extract unique channels (no avatars)
        tubeLog.notice("fetchSubscribedChannels: guide returned 0 — falling back to video tile parse")
        var tvBody = makeBody(client: tvClientContext)
        tvBody["browseId"] = "FEsubscriptions"
        let tvData = try await postTV(endpoint: "browse", body: tvBody)
        return parseSubscribedChannels(from: tvData)
    }

    /// Fetches watch history (requires auth).
    public func fetchHistory(continuationToken: String? = nil) async throws -> VideoGroup {
        var body = makeBody(client: tvClientContext, continuationToken: continuationToken)
        if continuationToken == nil {
            body["browseId"] = "FEhistory"
        }
        let data = try await postTV(endpoint: "browse", body: body)
        return try parseVideoGroup(from: data, title: "History")
    }

    // MARK: - Search

    public func search(
        query: String,
        continuationToken: String? = nil,
        filter: SearchFilter = .default
    ) async throws -> VideoGroup {
        var body = makeBody(client: webClientContext, continuationToken: continuationToken)
        if continuationToken == nil {
            body["query"] = query
            if let params = filter.encodedParams() {
                body["params"] = params
            }
        }
        let data = try await post(endpoint: "search", body: body)
        return try parseVideoGroup(from: data, title: "Search: \(query)")
    }

    public func fetchSearchSuggestions(query: String) async throws -> [String] {
        guard var components = URLComponents(string: "https://suggestqueries-clients6.youtube.com/complete/search") else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "client", value: "youtube"),
            URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "callback", value: ""),
        ]
        guard let url = components.url else { return [] }
        #if DEBUG
        print("[Suggestions] Fetching suggestions")
        #endif
        let (data, response) = try await session.data(from: url)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("[Suggestions] HTTP status: \(statusCode), bytes: \(data.count)")
        // Response format: [query, [[suggestion, 0, []], ...], ...]
        guard let raw = String(data: data, encoding: .utf8) else {
            print("[Suggestions] Failed to decode response as UTF-8")
            return []
        }
        // Extract the outermost JSON array — works regardless of callback wrapper name
        guard let arrayStart = raw.firstIndex(of: "["),
              let arrayEnd = raw.lastIndex(of: "]") else {
            print("[Suggestions] Could not find JSON array bounds")
            return []
        }
        let jsonString = String(raw[arrayStart...arrayEnd])
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [Any]
        else {
            print("[Suggestions] JSON parse failed")
            return []
        }
        guard let suggestions = json[safe: 1] as? [[Any]] else {
            print("[Suggestions] Unexpected JSON shape: \(json.prefix(2))")
            return []
        }
        let results = suggestions.compactMap { $0[safe: 0] as? String }
        print("[Suggestions] Parsed \(results.count) suggestions: \(results.prefix(5))")
        return results
    }

    // MARK: - Shorts

    public func fetchShorts() async throws -> VideoGroup {
        // NOTE (2026-05-24): Strategies 1–3 (FEshorts via postTV, postTVCategory, WEB)
        // were removed because YouTube deprecated the FEshorts browseId — all three
        // returned HTTP 400 on every client (TV+auth, TV-category, WEB). Confirmed via
        // log analysis: the home browse with the same token/version succeeds (200), so
        // it is specifically FEshorts that YouTube no longer accepts, not a client version
        // or auth issue. yt-dlp (2026.03.17) does not use FEshorts at all and does not
        // support the Shorts homepage feed. Search is the only working path right now.
        // TODO: re-add a FEshorts attempt if YouTube re-enables it, or find a replacement
        // browseId/params that yields a Shorts feed.

        // Search "#shorts" with the YouTube Shorts duration filter (EgIYAQ== / sp=EgIYAQ%3D%3D).
        // WEB client videoRenderer items in search results rarely carry reelWatchEndpoint or
        // the SHORTS overlay style, so parseVideoRenderer leaves isShort=false for most of them
        // even though they are genuine Shorts. Since the duration:short filter guarantees
        // every result is ≤ 4 min and we searched for "#shorts", we treat any video ≤ 180 s
        // as a Short and override isShort in-place.
        let shortsFilter = SearchFilter(duration: .short)
        let searchGroup = try await search(query: "#shorts", filter: shortsFilter)
        // Accept videos already flagged isShort=true by the parser (shortsLockupViewModel sets
        // isShort=true directly), OR any video with duration ≤ 180 s that wasn't flagged.
        // Do NOT reject on nil duration — shortsLockupViewModel items have nil duration.
        var shorts = searchGroup.videos.filter { $0.isShort || ($0.duration.map { $0 <= 180 } ?? false) }
        for i in shorts.indices where !shorts[i].isShort { shorts[i].isShort = true }
        let dropped = searchGroup.videos.filter { !($0.isShort || ($0.duration.map { $0 <= 180 } ?? false)) }
        tubeLog.notice("fetchShorts search → \(searchGroup.videos.count, privacy: .public) total, \(shorts.count, privacy: .public) kept as shorts (\(dropped.count, privacy: .public) dropped), hasMore=\(searchGroup.nextPageToken != nil, privacy: .public)")
        // Tag token with "srch:" so fetchShortsMore() uses only the search continuation path.
        return VideoGroup(title: "Shorts", videos: shorts, nextPageToken: searchGroup.nextPageToken.map { "srch:" + $0 })
    }

    public func fetchShortsMore(continuationToken: String) async throws -> VideoGroup {
        // InnerTube continuation tokens are client-specific: a token issued by one
        // client (e.g. postTV) returns HTTP 400 when sent to a different client
        // (e.g. WEB). fetchShorts() embeds a source prefix in every token it returns
        // so we can route the continuation to the correct client without retrying all.
        //
        // Prefix  Client         Auth needed
        // "stv:"  postTV         yes (Bearer)
        // "stvc:" postTVCategory no
        // "web:"  WEB browse     no
        // "srch:" search         no
        // ""      legacy         try-all (backward compat)
        let (source, rawToken): (String, String) = {
            let tagged: [(String, String)] = [
                ("stv:", "stv"), ("stvc:", "stvc"), ("web:", "web"), ("srch:", "srch")
            ]
            for (prefix, tag) in tagged where continuationToken.hasPrefix(prefix) {
                return (tag, String(continuationToken.dropFirst(prefix.count)))
            }
            return ("", continuationToken)
        }()
        tubeLog.notice("fetchShortsMore source=\(source.isEmpty ? "legacy" : source, privacy: .public) continuation=present")
        let isAuth = authToken != nil

        switch source {
        case "stv":
            let body = makeBody(client: tvClientContext, continuationToken: rawToken)
            let data = try await postTV(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "Shorts")
            let shorts = group.videos.filter { $0.isShort }
            tubeLog.notice("fetchShortsMore postTV → \(group.videos.count, privacy: .public) videos, \(shorts.count, privacy: .public) shorts")
            return VideoGroup(title: "Shorts", videos: shorts, nextPageToken: group.nextPageToken.map { "stv:" + $0 })

        case "stvc":
            let body = makeBody(client: tvClientContext, continuationToken: rawToken)
            let data = try await postTVCategory(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "Shorts")
            let shorts = group.videos.filter { $0.isShort }
            tubeLog.notice("fetchShortsMore postTVCategory → \(group.videos.count, privacy: .public) videos, \(shorts.count, privacy: .public) shorts")
            return VideoGroup(title: "Shorts", videos: shorts, nextPageToken: group.nextPageToken.map { "stvc:" + $0 })

        case "web":
            let body = makeBody(client: webClientContext, continuationToken: rawToken)
            let data = try await post(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "Shorts")
            let shorts = group.videos.filter { $0.isShort }
            tubeLog.notice("fetchShortsMore WEB → \(group.videos.count, privacy: .public) videos, \(shorts.count, privacy: .public) shorts")
            return VideoGroup(title: "Shorts", videos: shorts, nextPageToken: group.nextPageToken.map { "web:" + $0 })

        case "srch":
            let group = try await search(query: "#shorts", continuationToken: rawToken)
            var shorts = group.videos.filter { $0.isShort || ($0.duration.map { $0 <= 180 } ?? false) }
            for i in shorts.indices where !shorts[i].isShort { shorts[i].isShort = true }
            let dropped = group.videos.filter { !($0.isShort || ($0.duration.map { $0 <= 180 } ?? false)) }
            tubeLog.notice("fetchShortsMore search → \(group.videos.count, privacy: .public) total, \(shorts.count, privacy: .public) kept (\(dropped.count, privacy: .public) dropped), nextToken=\(group.nextPageToken != nil ? "yes" : "no", privacy: .public)")
            return VideoGroup(title: "Shorts", videos: shorts, nextPageToken: group.nextPageToken.map { "srch:" + $0 })

        default:
            // Legacy un-prefixed token (from older app versions): try all clients as before.
            if isAuth {
                do {
                    let body = makeBody(client: tvClientContext, continuationToken: rawToken)
                    let data = try await postTV(endpoint: "browse", body: body)
                    let group = try parseVideoGroup(from: data, title: "Shorts")
                    let shorts = group.videos.filter { $0.isShort }
                    tubeLog.notice("fetchShortsMore postTV → \(group.videos.count, privacy: .public) videos, \(shorts.count, privacy: .public) shorts, hasMore=\(group.nextPageToken != nil, privacy: .public)")
                    if !group.videos.isEmpty {
                        return VideoGroup(title: "Shorts", videos: shorts, nextPageToken: group.nextPageToken)
                    }
                } catch {
                    tubeLog.notice("fetchShortsMore postTV failed (\(error, privacy: .public)) — trying postTVCategory")
                }
            }

            do {
                let body = makeBody(client: tvClientContext, continuationToken: rawToken)
                let data = try await postTVCategory(endpoint: "browse", body: body)
                let group = try parseVideoGroup(from: data, title: "Shorts")
                let shorts = group.videos.filter { $0.isShort }
                tubeLog.notice("fetchShortsMore postTVCategory → \(group.videos.count, privacy: .public) videos, \(shorts.count, privacy: .public) shorts, hasMore=\(group.nextPageToken != nil, privacy: .public)")
                if !group.videos.isEmpty {
                    return VideoGroup(title: "Shorts", videos: shorts, nextPageToken: group.nextPageToken)
                }
            } catch {
                tubeLog.notice("fetchShortsMore postTVCategory failed (\(error, privacy: .public)) — trying WEB")
            }

            do {
                let body = makeBody(client: webClientContext, continuationToken: rawToken)
                let data = try await post(endpoint: "browse", body: body)
                let group = try parseVideoGroup(from: data, title: "Shorts")
                let shorts = group.videos.filter { $0.isShort }
                tubeLog.notice("fetchShortsMore WEB → \(group.videos.count, privacy: .public) videos, \(shorts.count, privacy: .public) shorts, hasMore=\(group.nextPageToken != nil, privacy: .public)")
                if !group.videos.isEmpty {
                    return VideoGroup(title: "Shorts", videos: shorts, nextPageToken: group.nextPageToken)
                }
            } catch {
                tubeLog.notice("fetchShortsMore WEB failed (\(error, privacy: .public)) — trying search continuation")
            }

            // Last resort: search continuation token.
            let searchGroup = try await search(query: "#shorts", continuationToken: rawToken)
            let searchShorts = searchGroup.videos.filter { $0.isShort }
            tubeLog.notice("fetchShortsMore search → \(searchGroup.videos.count, privacy: .public) total, \(searchShorts.count, privacy: .public) shorts, hasMore=\(searchGroup.nextPageToken != nil, privacy: .public)")
            return VideoGroup(title: "Shorts", videos: searchShorts, nextPageToken: searchGroup.nextPageToken)
        }
    }

    // MARK: - Category sections

    public func fetchMusic() async throws -> VideoGroup {
        do {
            // FEmusic_home is the TVHTML5 browse ID for the music category page.
            var body = makeBody(client: tvClientContext)
            body["browseId"] = "FEmusic_home"
            let data = try await postTVCategory(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "Music")
            if !group.videos.isEmpty { return group }
        } catch {
            tubeLog.notice("fetchMusic browse failed, falling back to search: \(error, privacy: .public)")
        }
        return try await search(query: "music")
    }

    public func fetchGaming() async throws -> VideoGroup {
        do {
            // FEgaming requires TVHTML5 context on www.youtube.com (not googleapis.com).
            var body = makeBody(client: tvClientContext)
            body["browseId"] = "FEgaming"
            let data = try await postTVCategory(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "Gaming")
            if !group.videos.isEmpty { return group }
        } catch {
            tubeLog.notice("fetchGaming browse failed, falling back to search: \(error, privacy: .public)")
        }
        return try await search(query: "gaming")
    }

    public func fetchNews() async throws -> VideoGroup {
        // FEnews is not a valid InnerTube browse ID — use search directly.
        return try await search(query: "news today")
    }

    public func fetchLive() async throws -> VideoGroup {
        do {
            var body = makeBody(client: tvClientContext)
            body["browseId"] = "FElive_home"
            let data = try await postTVCategory(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "Live")
            if !group.videos.isEmpty { return group }
        } catch {
            tubeLog.notice("fetchLive browse failed, falling back to search: \(error, privacy: .public)")
        }
        return try await search(query: "live stream")
    }

    public func fetchSports() async throws -> VideoGroup {
        do {
            // FEsportsau is the known TVHTML5 browse ID for the sports category.
            var body = makeBody(client: tvClientContext)
            body["browseId"] = "FEsportsau"
            let data = try await postTVCategory(endpoint: "browse", body: body)
            let group = try parseVideoGroup(from: data, title: "Sports")
            if !group.videos.isEmpty { return group }
        } catch {
            tubeLog.notice("fetchSports browse failed, falling back to search: \(error, privacy: .public)")
        }
        return try await search(query: "sports")
    }
}
