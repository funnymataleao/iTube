import Foundation
import SmartTubeIOSCore

/// Last-resort playback transport for tvOS when YouTube bot-gates the device's
/// own `/player` request. The companion running on the user's Mac resolves the
/// normal VisionOS HLS stream and proxies the manifest and media bytes over LAN.
///
/// The regular InnerTube path always runs first. This service is only consulted
/// after that path fails, so social actions and authenticated browsing remain
/// direct between the Apple TV and YouTube.
enum LANPlaybackRelay {
    struct ResolvedVideo: Sendable {
        struct AudioSource: Sendable {
            let track: AudioTrack
            let format: VideoFormat
        }

        let hlsURL: URL
        let title: String?
        let author: String?
        let description: String?
        let publishedAt: Date?
        let viewCount: Int?
        let duration: TimeInterval?
        let formats: [VideoFormat]
        let audioSources: [AudioSource]
        let captions: [CaptionTrack]

        var audioTracks: [AudioTrack] {
            audioSources.map(\.track)
        }

        private func preferredAudioSource(language: String?) -> AudioSource? {
            if let language, language == "original" {
                return audioSources.first(where: { $0.track.isOriginal })
                    ?? audioSources.first
            }
            if let language {
                if let exact = audioSources.first(where: { $0.track.languageCode == language }) {
                    return exact
                }
                let base = language.components(separatedBy: "-").first ?? language
                if let baseMatch = audioSources.first(where: {
                    ($0.track.languageCode.components(separatedBy: "-").first
                        ?? $0.track.languageCode) == base
                }) {
                    return baseMatch
                }
            }
            return audioSources.first(where: { $0.track.isOriginal })
                ?? audioSources.first
        }

        func playerInfo(
            for fallbackVideo: Video,
            metadata: PlayerInfo?,
            preferredAudioLanguage: String?
        ) -> PlayerInfo {
            var video = metadata?.video ?? fallbackVideo
            if video.description?.isEmpty != false {
                video.description = fallbackVideo.description
            }
            if video.thumbnailURL == nil {
                video.thumbnailURL = fallbackVideo.thumbnailURL
            }
            if video.publishedAt == nil {
                video.publishedAt = fallbackVideo.publishedAt
            }
            if video.publishedTimeText?.isEmpty != false {
                video.publishedTimeText = fallbackVideo.publishedTimeText
            }
            if video.channelId?.isEmpty != false {
                video.channelId = fallbackVideo.channelId
            }
            if video.title.isEmpty || video.title == video.id {
                video.title = title ?? video.title
            }
            if video.channelTitle.isEmpty {
                video.channelTitle = author ?? video.channelTitle
            }
            if let description, !description.isEmpty {
                video.description = description
            }
            if let publishedAt {
                video.publishedAt = publishedAt
            }
            if let viewCount {
                video.viewCount = viewCount
            }
            if video.duration == nil {
                video.duration = duration
            }

            // The relay URL is a standards-compliant fMP4 HLS master. Keep the
            // master intact so AVPlayer retains ABR, seeking, and its native audio
            // rendition group; selecting an individual adaptive MP4 drops audio.
            _ = preferredAudioSource(language: preferredAudioLanguage)
            return PlayerInfo(
                video: video,
                formats: formats,
                hlsURL: hlsURL,
                dashURL: nil,
                captionTracks: captions.isEmpty ? (metadata?.captionTracks ?? []) : captions,
                trackingURLs: metadata?.trackingURLs,
                endCards: metadata?.endCards ?? []
            )
        }
    }

    enum RelayError: LocalizedError {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason):
                return "Playback relay unavailable: \(reason)"
            }
        }
    }

    private struct Response: Decodable {
        let url: URL
        let title: String?
        let author: String?
        let description: String?
        let publishedAt: Date?
        let viewCount: Int?
        let duration: TimeInterval?
        let formats: [Format]
        let audioTracks: [Audio]
        let captions: [Caption]
    }

    private struct Format: Decodable {
        let label: String
        let width: Int
        let height: Int
        let fps: Int
        let mimeType: String
        let url: URL
        let bitrate: Int?
    }

    private struct Caption: Decodable {
        let id: String
        let url: URL
        let name: String
        let languageCode: String
        let isAutoGenerated: Bool
    }

    private struct Audio: Decodable {
        let id: String
        let name: String
        let languageCode: String
        let isOriginal: Bool
        let mimeType: String
        let url: URL
        let bitrate: Int?
    }

    private static var candidateBaseURLs: [URL] {
        var raw: [String] = []
        if let override = ProcessInfo.processInfo.environment["PERSONALTUBE_RELAY_URL"],
           !override.isEmpty {
            raw.append(override)
        }
        if let saved = UserDefaults.standard.string(forKey: "PersonalTubePlaybackRelayURL"),
           !saved.isEmpty {
            raw.append(saved)
        }
        raw.append("http://MacBook-Pro-M5.local:8766")
        raw.append("http://192.168.1.104:8766")

        var seen = Set<String>()
        return raw.compactMap { value in
            let normalized = value.hasSuffix("/") ? String(value.dropLast()) : value
            guard seen.insert(normalized).inserted else { return nil }
            return URL(string: normalized)
        }
    }

    static func resolve(videoID: String) async throws -> ResolvedVideo {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 7
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)

        var failures: [String] = []
        for baseURL in candidateBaseURLs {
            guard var components = URLComponents(
                url: baseURL.appendingPathComponent("resolve"),
                resolvingAgainstBaseURL: false
            ) else { continue }
            components.queryItems = [URLQueryItem(name: "videoId", value: videoID)]
            guard let url = components.url else { continue }

            do {
                var request = URLRequest(url: url)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw RelayError.unavailable("non-HTTP response from \(baseURL.host ?? "unknown host")")
                }
                guard (200..<300).contains(http.statusCode) else {
                    let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
                    throw RelayError.unavailable("HTTP \(http.statusCode) \(body)")
                }

                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let decoded = try decoder.decode(Response.self, from: data)
                let formats = decoded.formats.map {
                    VideoFormat(
                        label: $0.label,
                        width: $0.width,
                        height: $0.height,
                        fps: $0.fps,
                        mimeType: $0.mimeType,
                        url: $0.url,
                        bitrate: $0.bitrate
                    )
                }
                let captions = decoded.captions.map {
                    CaptionTrack(
                        id: $0.id,
                        baseURL: $0.url,
                        name: $0.name,
                        languageCode: $0.languageCode,
                        isAutoGenerated: $0.isAutoGenerated
                    )
                }
                let audioSources = decoded.audioTracks.map {
                    ResolvedVideo.AudioSource(
                        track: AudioTrack(
                            id: $0.id,
                            name: $0.name,
                            languageCode: $0.languageCode,
                            isOriginal: $0.isOriginal,
                            contentID: $0.id
                        ),
                        format: VideoFormat(
                            label: $0.name,
                            width: 0,
                            height: 0,
                            fps: 0,
                            mimeType: $0.mimeType,
                            url: $0.url,
                            bitrate: $0.bitrate
                        )
                    )
                }
                return ResolvedVideo(
                    hlsURL: decoded.url,
                    title: decoded.title,
                    author: decoded.author,
                    description: decoded.description,
                    publishedAt: decoded.publishedAt,
                    viewCount: decoded.viewCount,
                    duration: decoded.duration,
                    formats: formats,
                    audioSources: audioSources,
                    captions: captions
                )
            } catch {
                failures.append("\(baseURL.host ?? baseURL.absoluteString): \(error.localizedDescription)")
            }
        }

        throw RelayError.unavailable(failures.joined(separator: "; "))
    }
}
