import Foundation

// MARK: - Official YouTube Data API video topic enrichment

extension InnerTubeAPI {
    /// Fetches uploader-selected category IDs and tags for the supplied videos.
    /// Requests are batched so a subscriptions page adds only a small number of
    /// documented Data API reads, and callers can persist the result locally.
    public func fetchVideoTopicMetadata(
        videoIDs: [String]
    ) async throws -> [String: VideoTopicMetadata] {
        let uniqueIDs = videoIDs.reduce(into: [String]()) { result, videoID in
            guard !videoID.isEmpty, !result.contains(videoID) else { return }
            result.append(videoID)
        }
        guard !uniqueIDs.isEmpty else { return [:] }

        var result: [String: VideoTopicMetadata] = [:]
        for startIndex in stride(from: 0, to: uniqueIDs.count, by: 50) {
            let endIndex = min(startIndex + 50, uniqueIDs.count)
            let batch = Array(uniqueIDs[startIndex..<endIndex])
            let batchResult = try await fetchVideoTopicMetadataBatch(videoIDs: batch)
            result.merge(batchResult) { _, newest in newest }
        }
        return result
    }

    private func fetchVideoTopicMetadataBatch(
        videoIDs: [String]
    ) async throws -> [String: VideoTopicMetadata] {
        guard let token = authToken else { throw APIError.notAuthenticated }

        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")
        components?.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "id", value: videoIDs.joined(separator: ",")),
            URLQueryItem(name: "fields", value: "items(id,snippet(categoryId,tags,publishedAt))"),
        ]
        guard let url = components?.url else {
            throw APIError.invalidURL("youtube/v3/videos")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(InnerTubeClients.TV.actionUserAgent, forHTTPHeaderField: "User-Agent")
        if let accountPageId, !accountPageId.isEmpty {
            request.setValue(accountPageId, forHTTPHeaderField: "X-Goog-PageId")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unavailable("YouTube videos.list returned no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.unavailable("YouTube videos.list HTTP \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]]
        else {
            throw APIError.decodingError("YouTube videos.list returned invalid JSON")
        }

        var result: [String: VideoTopicMetadata] = [:]
        for item in items {
            guard let videoID = item["id"] as? String, !videoID.isEmpty else { continue }
            let snippet = item["snippet"] as? [String: Any]
            result[videoID] = VideoTopicMetadata(
                videoID: videoID,
                categoryID: snippet?["categoryId"] as? String,
                tags: snippet?["tags"] as? [String] ?? [],
                publishedAt: Self.parsePublishedAt(snippet?["publishedAt"] as? String)
            )
        }
        return result
    }

    private nonisolated static func parsePublishedAt(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        // YouTube normally returns whole seconds, but the API contract permits
        // RFC 3339 fractional seconds as well. Local formatter instances avoid
        // sharing non-Sendable formatter state across actor re-entrancy.
        let standard = ISO8601DateFormatter()
        if let date = standard.date(from: value) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }
}
