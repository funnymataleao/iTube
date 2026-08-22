import Foundation

// MARK: - YouTube channel subscriptions

extension InnerTubeAPI {
    public func subscribe(channelId: String) async throws {
        let id = try await normalizedChannelId(channelId)
        do {
            try await insertDataAPISubscription(channelId: id)
        } catch APIError.notAuthenticated {
            throw APIError.notAuthenticated
        } catch {
            let dataAPIError = error
            do {
                try await mutateSubscriptionViaInnerTube(endpoint: "subscription/subscribe", channelId: id)
            } catch {
                throw combinedSubscriptionError(dataAPIError: dataAPIError, innerTubeError: error)
            }
        }
    }

    public func unsubscribe(channelId: String) async throws {
        let id = try await normalizedChannelId(channelId)
        do {
            guard let subscriptionId = try await dataAPISubscriptionId(channelId: id) else {
                // The desired server state is already true: the channel is not subscribed.
                return
            }
            try await deleteDataAPISubscription(subscriptionId: subscriptionId)
        } catch APIError.notAuthenticated {
            throw APIError.notAuthenticated
        } catch {
            let dataAPIError = error
            do {
                try await mutateSubscriptionViaInnerTube(endpoint: "subscription/unsubscribe", channelId: id)
            } catch {
                throw combinedSubscriptionError(dataAPIError: dataAPIError, innerTubeError: error)
            }
        }
    }

    private func normalizedChannelId(_ channelId: String) async throws -> String {
        let id = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw APIError.unavailable("Missing channel") }
        let resolved = id.hasPrefix("@") ? try await resolveChannelHandle(id) : id
        let suffix = resolved.dropFirst(2)
        guard resolved.hasPrefix("UC"), resolved.count == 24,
              suffix.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            throw APIError.unavailable("Could not resolve channel ID for \(id)")
        }
        return resolved
    }

    // MARK: Official YouTube Data API

    /// The documented subscriptions API is used for user mutations. YouTube's
    /// private InnerTube subscription endpoint can reject otherwise valid TV
    /// OAuth tokens with HTTP 400, while this endpoint is covered by the
    /// `youtube` scope already granted by the device-code sign-in flow.
    private func dataAPISubscriptionId(channelId: String) async throws -> String? {
        let url = try dataAPISubscriptionsURL(queryItems: [
            URLQueryItem(name: "part", value: "id"),
            URLQueryItem(name: "mine", value: "true"),
            URLQueryItem(name: "forChannelId", value: channelId),
            URLQueryItem(name: "maxResults", value: "1"),
            URLQueryItem(name: "fields", value: "items(id)"),
        ])
        var request = try authenticatedDataAPIRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        let json = try validatedDataAPIJSON(data: data, response: response, operation: "subscriptions.list")
        let items = json["items"] as? [[String: Any]]
        return items?.first?["id"] as? String
    }

    private func insertDataAPISubscription(channelId: String) async throws {
        let url = try dataAPISubscriptionsURL(queryItems: [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "fields", value: "id"),
        ])
        var request = try authenticatedDataAPIRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "snippet": [
                "resourceId": [
                    "kind": "youtube#channel",
                    "channelId": channelId,
                ],
            ],
        ])

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse,
           http.statusCode == 400,
           dataAPIErrorReason(data: data) == "subscriptionDuplicate" {
            // Idempotent success: the requested server state already exists.
            return
        }
        _ = try validatedDataAPIJSON(data: data, response: response, operation: "subscriptions.insert")
    }

    private func deleteDataAPISubscription(subscriptionId: String) async throws {
        let url = try dataAPISubscriptionsURL(queryItems: [
            URLQueryItem(name: "id", value: subscriptionId),
        ])
        var request = try authenticatedDataAPIRequest(url: url)
        request.httpMethod = "DELETE"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unavailable("YouTube subscriptions.delete returned no HTTP response")
        }
        if http.statusCode == 204 {
            return
        }
        if http.statusCode == 404,
           dataAPIErrorReason(data: data) == "subscriptionNotFound" {
            return
        }
        _ = try validatedDataAPIJSON(data: data, response: response, operation: "subscriptions.delete")
    }

    private func dataAPISubscriptionsURL(queryItems: [URLQueryItem]) throws -> URL {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/subscriptions")
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw APIError.invalidURL("youtube/v3/subscriptions")
        }
        return url
    }

    private func authenticatedDataAPIRequest(url: URL) throws -> URLRequest {
        guard let token = authToken else { throw APIError.notAuthenticated }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(InnerTubeClients.TV.actionUserAgent, forHTTPHeaderField: "User-Agent")
        if let accountPageId, !accountPageId.isEmpty {
            request.setValue(accountPageId, forHTTPHeaderField: "X-Goog-PageId")
        }
        return request
    }

    private func validatedDataAPIJSON(
        data: Data,
        response: URLResponse,
        operation: String
    ) throws -> [String: Any] {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unavailable("YouTube \(operation) returned no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let reason = dataAPIErrorReason(data: data) ?? "unknown"
            let message = dataAPIErrorMessage(data: data) ?? "YouTube rejected the request"
            throw APIError.unavailable("YouTube \(operation) HTTP \(http.statusCode): \(reason) — \(message)")
        }
        guard !data.isEmpty else { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decodingError("YouTube \(operation) returned invalid JSON")
        }
        return json
    }

    private func dataAPIErrorReason(data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let errors = error["errors"] as? [[String: Any]]
        else { return nil }
        return errors.first?["reason"] as? String
    }

    private func dataAPIErrorMessage(data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any]
        else { return nil }
        return error["message"] as? String
    }

    private func combinedSubscriptionError(dataAPIError: Error, innerTubeError: Error) -> APIError {
        APIError.unavailable(
            "Subscription mutation failed. Data API: \(String(describing: dataAPIError)); "
            + "InnerTube: \(String(describing: innerTubeError))"
        )
    }

    // MARK: Private InnerTube compatibility transport

    /// Kept for other authenticated action call sites. Subscription controls use
    /// the documented Data API above instead of this private YouTube endpoint.
    private func mutateSubscriptionViaInnerTube(endpoint: String, channelId: String) async throws {
        let preferredLanguage = Locale.preferredLanguages.first?
            .split(separator: "-")
            .first
            .map(String.init) ?? "en"
        let region = Locale.current.region?.identifier ?? "US"
        let utcOffsetMinutes = String(TimeZone.current.secondsFromGMT() / 60)

        var client: [String: Any] = [
            "clientName": InnerTubeClients.TV.name,
            "clientVersion": InnerTubeClients.TV.version,
            "clientScreen": "WATCH",
            "userAgent": InnerTubeClients.TV.actionUserAgent,
            "browserName": "Cobalt",
            "browserVersion": "22.lts.3.306369-gold",
            "tvAppInfo": [
                "appQuality": "TV_APP_QUALITY_FULL_ANIMATION",
                "zylonLeftNav": true,
            ],
            "webpSupport": false,
            "animatedWebpSupport": true,
            "acceptLanguage": preferredLanguage,
            "acceptRegion": region,
            "utcOffsetMinutes": utcOffsetMinutes,
            "visitorData": visitorData ?? "",
        ]
        if let visitorData, !visitorData.isEmpty {
            client["visitorData"] = visitorData
        }

        let body: [String: Any] = [
            "context": [
                "client": client,
                "user": [
                    "enableSafetyMode": false,
                    "lockedSafetyMode": false,
                ],
            ],
            "racyCheckOk": true,
            "contentCheckOk": true,
            "channelIds": [channelId],
            // SmartTube includes params even when the renderer supplies none.
            "params": "",
        ]
        _ = try await postAuthenticatedMutation(endpoint: endpoint, body: body)
    }

    public func isSubscribed(to channelId: String) async throws -> Bool {
        let originalId = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originalId.isEmpty else { throw APIError.unavailable("Missing channel") }
        let canonicalId = try await normalizedChannelId(originalId)
        do {
            return try await dataAPISubscriptionId(channelId: canonicalId) != nil
        } catch APIError.notAuthenticated {
            throw APIError.notAuthenticated
        } catch {
            // Keep the UI usable if the Data API project is temporarily unavailable.
            let channels = try await fetchSubscribedChannels()
            return channels.contains {
                $0.id == canonicalId
                    || $0.id.caseInsensitiveCompare(originalId) == .orderedSame
            }
        }
    }
}
