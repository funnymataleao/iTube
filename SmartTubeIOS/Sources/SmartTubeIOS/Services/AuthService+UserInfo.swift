import Foundation
import SmartTubeIOSCore

extension AuthService {

    // MARK: - User info

    func fetchUserInfo() async throws {
        authLog.notice("fetchUserInfo() — calling validAccessToken()")
        let token = try await validAccessToken()
        authLog.notice("fetchUserInfo() — authenticated request ready, calling accounts list API")
        // Android methodology: POST to www.youtube.com/youtubei/v1/account/accounts_list
        // with TV client context + accountReadMask. Mirrors AuthApi.java @POST accounts_list
        // and AuthApiHelper.getAccountsListQuery() which uses PostDataHelper.createQueryTV().
        var components = URLComponents(url: Self.accountsListURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")]
        guard let accountsURL = components?.url else { throw AuthError.configurationError }
        var req = URLRequest(url: accountsURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        req.setValue(InnerTubeClients.TV.actionUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.youtube.com/tv", forHTTPHeaderField: "Referer")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let preferredLanguage = Locale.preferredLanguages.first?
            .split(separator: "-")
            .first
            .map(String.init) ?? "en"
        let region = Locale.current.region?.identifier ?? "US"
        let body: [String: Any] = [
            "context": [
                "client": [
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
                    "utcOffsetMinutes": String(TimeZone.current.secondsFromGMT() / 60),
                    "visitorData": "",
                ],
                "user": [
                    "enableSafetyMode": false,
                    "lockedSafetyMode": false,
                ],
            ],
            "racyCheckOk": true,
            "contentCheckOk": true,
            "accountReadMask": [
                "returnOwner": true,
                "returnBrandAccounts": true,
                "returnPersonaAccounts": false
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        authLog.notice("fetchUserInfo() — HTTP \(statusCode)")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            authLog.error("fetchUserInfo() — JSON parse failed")
            return
        }
        let accountItem = extractAccountItem(from: json)
        guard let item = accountItem else {
            authLog.error("fetchUserInfo() — could not find accountItem; top-level keys=\(Array(json.keys))")
            return
        }
        if let nameDict = item["accountName"] as? [String: Any] {
            accountName = (nameDict["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
                ?? nameDict["simpleText"] as? String
        }
        authLog.notice("fetchUserInfo() — account name \(self.accountName == nil ? "missing" : "loaded")")
        if let photoDict = item["accountPhoto"] as? [String: Any],
           let thumbnails = photoDict["thumbnails"] as? [[String: Any]],
           let last = thumbnails.last,
           let urlStr = last["url"] as? String {
            accountAvatarURL = URL(string: urlStr.hasPrefix("//") ? "https:\(urlStr)" : urlStr)
            authLog.notice("fetchUserInfo() — account avatar loaded")
        }
        accountPageId = extractPageId(from: item)
        authLog.notice("fetchUserInfo() — selected pageId=\(self.accountPageId == nil ? "none" : "present")")
        saveToKeychain()
    }

    /// Walk Android's AccountsList JSON path:
    /// contents[0].accountSectionListRenderer.contents[0].accountItemSectionRenderer.contents[].accountItem
    /// Returns the first account with isSelected==true, or the first available account.
    func extractAccountItem(from json: [String: Any]) -> [String: Any]? {
        guard let contents = json["contents"] as? [[String: Any]],
              let firstSection = contents.first,
              let sectionListRenderer = firstSection["accountSectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]],
              let firstItemSection = sectionContents.first,
              let itemSectionRenderer = firstItemSection["accountItemSectionRenderer"] as? [String: Any],
              let items = itemSectionRenderer["contents"] as? [[String: Any]]
        else { return nil }
        return items.compactMap { $0["accountItem"] as? [String: Any] }
            .first(where: { $0["isSelected"] as? Bool == true })
            ?? items.compactMap { $0["accountItem"] as? [String: Any] }.first
    }

    /// Matches SmartTube's AccountInt pageIdToken extraction for the selected
    /// YouTube identity. The actual value is intentionally never logged.
    func extractPageId(from accountItem: [String: Any]) -> String? {
        guard let serviceEndpoint = accountItem["serviceEndpoint"] as? [String: Any],
              let selectIdentity = serviceEndpoint["selectActiveIdentityEndpoint"] as? [String: Any],
              let supportedTokens = selectIdentity["supportedTokens"] as? [[String: Any]]
        else { return nil }

        return supportedTokens.compactMap { token in
            (token["pageIdToken"] as? [String: Any])?["pageId"] as? String
        }.first(where: { !$0.isEmpty })
    }
}
