import Foundation
import Network
import os
import SmartTubeIOSCore

private let onDeviceRelayLog = Logger(
    subsystem: "com.void.smarttube.app",
    category: "OnDevicePlaybackRelay"
)

/// A loopback-only HTTP transport that keeps YouTube's session headers attached to
/// HLS manifests and media requests made by AVFoundation.
///
/// The listener is bound explicitly to `127.0.0.1`, never advertised with Bonjour,
/// and accepts only opaque resources registered by this process. It therefore does
/// not depend on another computer, another app, or access to the user's LAN.
actor OnDevicePlaybackRelay {
    static let shared = OnDevicePlaybackRelay()

    private static func diagnosticLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--playback-diagnostics") else { return }
        print("[OnDeviceRelayHTTP] \(message())")
        #endif
    }

    enum RelayError: LocalizedError, Equatable {
        case listenerFailed(String)
        case listenerUnavailable
        case invalidUpstreamHost(String)
        case noPlayableStreams
        case invalidMP4Index
        case upstreamFailed(String)

        var errorDescription: String? {
            switch self {
            case .listenerFailed(let message):
                return "On-device playback listener failed: \(message)"
            case .listenerUnavailable:
                return "On-device playback listener is unavailable"
            case .invalidUpstreamHost(let host):
                return "Blocked playback upstream host: \(host)"
            case .noPlayableStreams:
                return "The player response did not contain a compatible HLS or MP4 stream"
            case .invalidMP4Index:
                return "The adaptive MP4 stream did not contain a usable SIDX index"
            case .upstreamFailed(let message):
                return "Playback upstream failed: \(message)"
            }
        }
    }

    struct MP4Index: Equatable, Sendable {
        struct Reference: Equatable, Sendable {
            let offset: Int64
            let size: Int64
            let duration: TimeInterval
        }

        let initializationLength: Int64
        let references: [Reference]
    }

    private struct IndexedFormat: Sendable {
        let format: VideoFormat
        let index: MP4Index
    }

    private enum ResourcePayload: Sendable {
        case virtual(Data, contentType: String)
        case upstream(URL, headers: [String: String], requiresRange: Bool)
    }

    private struct Resource: Sendable {
        let payload: ResourcePayload
        let createdAt: Date
    }

    private let listenerQueue = DispatchQueue(
        label: "com.void.smarttube.on-device-playback-relay",
        qos: .userInitiated
    )
    private let session: URLSession
    private var listener: NWListener?
    private var baseURL: URL?
    private var startWaiters: [CheckedContinuation<URL, any Error>] = []
    private var resources: [String: Resource] = [:]
    private var upstreamResourceIDs: [String: String] = [:]

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: configuration)
    }

    /// Returns an HLS URL served entirely by this Apple TV process.
    ///
    /// Existing YouTube HLS is recursively rewritten through the loopback server.
    /// When the response contains only separate adaptive MP4 tracks, a standards-
    /// compliant fMP4 HLS master is synthesized from their SIDX indexes.
    func prepareStream(
        from info: PlayerInfo,
        requestHeaders: [String: String]
    ) async throws -> URL {
        _ = try await ensureListener()
        pruneExpiredResources()

        var headers = requestHeaders
        headers["User-Agent"] = headers["User-Agent"] ?? InnerTubeClients.VisionOS.userAgent
        headers["Origin"] = headers["Origin"] ?? "https://www.youtube.com"
        headers["Referer"] = headers["Referer"] ?? "https://www.youtube.com/"
        headers["Accept-Encoding"] = "identity"

        // Prefer ranged MP4 over YouTube's native HLS. The native manifest can be
        // fetched successfully while its rqh=1 media segments are still rejected
        // by the CDN. A synthetic fMP4 HLS playlist keeps every init/segment byte
        // range inside this relay and therefore on the same IPv4 route that minted
        // the signed player URLs.
        let localURL = try await buildSyntheticHLS(
            formats: info.formats,
            headers: headers
        )
        onDeviceRelayLog.notice(
            "Built synthetic fMP4 HLS master for loopback playback"
        )
        Self.diagnosticLog("synthetic master ready")
        return localURL
    }

    /// Preserves account-bound metadata while replacing only the media transport.
    static func playerInfo(
        streamInfo: PlayerInfo,
        fallbackVideo: Video,
        metadata: PlayerInfo?,
        hlsURL: URL
    ) -> PlayerInfo {
        let fallbackMetadataVideo = metadata?.video ?? fallbackVideo
        var video = streamInfo.video

        if video.title.isEmpty || video.title == video.id {
            video.title = fallbackMetadataVideo.title
        }
        if video.channelTitle.isEmpty {
            video.channelTitle = fallbackMetadataVideo.channelTitle
        }
        if video.channelId?.isEmpty != false {
            video.channelId = fallbackMetadataVideo.channelId
        }
        if video.description?.isEmpty != false {
            video.description = fallbackMetadataVideo.description
        }
        if video.thumbnailURL == nil {
            video.thumbnailURL = fallbackMetadataVideo.thumbnailURL
        }
        if video.thumbnailCandidates?.isEmpty != false {
            video.thumbnailCandidates = fallbackMetadataVideo.thumbnailCandidates
        }
        if video.duration == nil {
            video.duration = fallbackMetadataVideo.duration
        }
        if video.viewCount == nil {
            video.viewCount = fallbackMetadataVideo.viewCount
        }
        if video.publishedAt == nil {
            video.publishedAt = fallbackMetadataVideo.publishedAt
        }
        if video.exactPublishedAt == nil {
            video.exactPublishedAt = fallbackMetadataVideo.exactPublishedAt
        }
        if video.publishedTimeText?.isEmpty != false {
            video.publishedTimeText = fallbackMetadataVideo.publishedTimeText
        }

        let captions = streamInfo.captionTracks.isEmpty
            ? (metadata?.captionTracks ?? [])
            : streamInfo.captionTracks

        return PlayerInfo(
            video: video,
            formats: streamInfo.formats,
            hlsURL: hlsURL,
            dashURL: nil,
            captionTracks: captions,
            trackingURLs: metadata?.trackingURLs ?? streamInfo.trackingURLs,
            endCards: metadata?.endCards ?? streamInfo.endCards
        )
    }

    // MARK: - Listener lifecycle

    private func ensureListener() async throws -> URL {
        if let baseURL { return baseURL }

        if listener == nil {
            let parameters = NWParameters.tcp
            // Binding both the listener and the client URL to IPv4 loopback keeps
            // the transport inside this process and avoids Local Network privacy.
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(.loopback),
                port: .any
            )

            let newListener: NWListener
            do {
                newListener = try NWListener(using: parameters)
            } catch {
                throw RelayError.listenerFailed(error.localizedDescription)
            }

            let queue = listenerQueue
            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                LoopbackHTTPConnection(connection: connection, relay: self)
                    .start(on: queue)
            }
            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = newListener?.port else {
                        Task { await self.listenerDidFail("ready without a port") }
                        return
                    }
                    Task { await self.listenerDidBecomeReady(port: port) }
                case .failed(let error):
                    Task { await self.listenerDidFail(String(describing: error)) }
                case .cancelled:
                    Task { await self.listenerWasCancelled() }
                default:
                    break
                }
            }
            listener = newListener
            newListener.start(queue: queue)
        }

        return try await withCheckedThrowingContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    private func listenerDidBecomeReady(port: NWEndpoint.Port) {
        guard let url = URL(string: "http://127.0.0.1:\(port.rawValue)") else {
            listenerDidFail("invalid loopback URL")
            return
        }
        baseURL = url
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume(returning: url) }
        onDeviceRelayLog.notice(
            "Loopback listener ready on 127.0.0.1:\(port.rawValue, privacy: .public)"
        )
    }

    private func listenerDidFail(_ message: String) {
        let waiters = startWaiters
        startWaiters.removeAll()
        baseURL = nil
        listener?.cancel()
        listener = nil
        waiters.forEach {
            $0.resume(throwing: RelayError.listenerFailed(message))
        }
        onDeviceRelayLog.error(
            "Loopback listener failed: \(message, privacy: .public)"
        )
    }

    private func listenerWasCancelled() {
        guard baseURL != nil || !startWaiters.isEmpty else { return }
        let waiters = startWaiters
        startWaiters.removeAll()
        baseURL = nil
        listener = nil
        waiters.forEach {
            $0.resume(throwing: RelayError.listenerUnavailable)
        }
    }

    // MARK: - HTTP resource serving

    fileprivate func response(for request: RelayHTTPRequest) async -> RelayHTTPResponse {
        guard request.method == "GET" || request.method == "HEAD" else {
            return .text(status: 405, "Method Not Allowed")
        }
        guard request.path.hasPrefix("/resource/") else {
            return .text(status: 404, "Not Found")
        }

        let identifier = String(request.path.dropFirst("/resource/".count))
        guard let resource = resources[identifier] else {
            return .text(status: 404, "Resource expired")
        }
        let suffix = URL(fileURLWithPath: identifier).pathExtension
        let range = request.headers["range"] ?? "none"
        Self.diagnosticLog("\(request.method) .\(suffix) range=\(range)")

        switch resource.payload {
        case .virtual(let data, let contentType):
            Self.diagnosticLog("local 200 bytes=\(data.count) type=\(contentType)")
            return RelayHTTPResponse(
                status: 200,
                headers: [
                    "Content-Type": contentType,
                    "Content-Length": String(data.count),
                    "Cache-Control": "no-store",
                    "Accept-Ranges": "bytes",
                ],
                body: request.method == "HEAD" ? Data() : data
            )

        case .upstream(let url, let headers, let requiresRange):
            return await proxyUpstream(
                url,
                headers: headers,
                requiresRange: requiresRange,
                clientRequest: request
            )
        }
    }

    private func proxyUpstream(
        _ url: URL,
        headers: [String: String],
        requiresRange: Bool,
        clientRequest: RelayHTTPRequest
    ) async -> RelayHTTPResponse {
        do {
            try Self.validateUpstream(url)
            var request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 30
            )
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }

            if let clientRange = clientRequest.headers["range"] {
                guard let bounded = Self.boundedRange(clientRange) else {
                    return .text(status: 416, "Unsupported Range")
                }
                request.setValue(bounded, forHTTPHeaderField: "Range")
            } else if requiresRange {
                request.setValue(
                    "bytes=0-\(Self.maximumRangeBytes - 1)",
                    forHTTPHeaderField: "Range"
                )
            }

            let upstream = try await Self.fetchUpstream(request, session: session)
            let data = upstream.body
            try Self.validateUpstream(upstream.url)
            let upstreamHost = upstream.url.host ?? "unknown"
            let upstreamRange = request.value(forHTTPHeaderField: "Range") ?? "none"
            Self.diagnosticLog(
                "upstream \(upstream.statusCode) host=\(upstreamHost) bytes=\(data.count) range=\(upstreamRange)"
            )

            let contentType = upstream.value(forHTTPHeaderField: "Content-Type") ?? ""
            let isPlaylist = Self.isPlaylist(
                data: data,
                contentType: contentType,
                url: upstream.url
            )

            var responseData = data
            var responseContentType = contentType.isEmpty
                ? "application/octet-stream"
                : contentType
            if isPlaylist,
               (200..<300).contains(upstream.statusCode),
               let manifest = String(data: data, encoding: .utf8) {
                let filtered = manifest.contains("#EXT-X-STREAM-INF")
                    ? filterHLSMasterManifest(
                        manifest,
                        maximumHeight: InnerTubeClients.VisionOS.maximumHLSHeight,
                        requiredVideoCodec: "avc1"
                    )
                    : manifest
                let rewritten = try Self.rewritePlaylist(
                    filtered,
                    baseURL: upstream.url
                ) { upstream in
                    try self.registerUpstream(
                        upstream,
                        headers: headers,
                        requiresRange: false,
                        preferredSuffix: Self.preferredSuffix(for: upstream)
                    )
                }
                responseData = Data(rewritten.utf8)
                responseContentType = "application/vnd.apple.mpegurl"
            }

            var responseHeaders: [String: String] = [
                "Content-Type": responseContentType,
                "Content-Length": String(responseData.count),
                "Cache-Control": "no-store",
                "Accept-Ranges": upstream.value(forHTTPHeaderField: "Accept-Ranges") ?? "bytes",
            ]
            if !isPlaylist,
               let contentRange = upstream.value(forHTTPHeaderField: "Content-Range") {
                responseHeaders["Content-Range"] = contentRange
            }

            return RelayHTTPResponse(
                status: upstream.statusCode,
                headers: responseHeaders,
                body: clientRequest.method == "HEAD" ? Data() : responseData
            )
        } catch {
            onDeviceRelayLog.error(
                "Upstream proxy failed: \(error.localizedDescription, privacy: .public)"
            )
            Self.diagnosticLog("upstream failed: \(error.localizedDescription)")
            return .text(status: 502, "Playback upstream unavailable")
        }
    }

    /// The primary transport is NIOPosix + NIOSSL/BoringSSL inside this process.
    /// This avoids the system TLS fingerprint rejected by GVS on some Apple TVs
    /// while preserving certificate and hostname validation. System transports
    /// remain last-resort fallbacks for unusual network configurations.
    private static func fetchUpstream(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> IPv4HTTPResponse {
        do {
            return try await StandaloneHTTPClient.data(for: request, timeout: 30)
        } catch let standaloneError {
            onDeviceRelayLog.notice(
                "Standalone upstream unavailable; trying system IPv4: \(standaloneError.localizedDescription, privacy: .public)"
            )
            do {
                return try await IPv4HTTPClient.data(for: request, timeout: 30)
            } catch let ipv4Error {
                onDeviceRelayLog.notice(
                    "System IPv4 unavailable; trying URLSession: \(ipv4Error.localizedDescription, privacy: .public)"
                )
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      let finalURL = http.url else {
                    throw RelayError.upstreamFailed("non-HTTP response")
                }
                var headers: [String: [String]] = [:]
                for (rawName, rawValue) in http.allHeaderFields {
                    let name = String(describing: rawName).lowercased()
                    headers[name, default: []].append(String(describing: rawValue))
                }
                return IPv4HTTPResponse(
                    url: finalURL,
                    statusCode: http.statusCode,
                    headers: headers,
                    body: data
                )
            }
        }
    }

    private func registerUpstream(
        _ url: URL,
        headers: [String: String],
        requiresRange: Bool,
        preferredSuffix: String
    ) throws -> URL {
        try Self.validateUpstream(url)
        guard let baseURL else { throw RelayError.listenerUnavailable }

        let headerKey = headers.keys.sorted().map {
            "\($0.lowercased())=\(headers[$0] ?? "")"
        }.joined(separator: "&")
        let key = "\(url.absoluteString)|\(requiresRange)|\(headerKey)"
        if let existingID = upstreamResourceIDs[key] {
            return baseURL
                .appendingPathComponent("resource")
                .appendingPathComponent(existingID)
        }

        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + preferredSuffix
        resources[identifier] = Resource(
            payload: .upstream(url, headers: headers, requiresRange: requiresRange),
            createdAt: Date()
        )
        upstreamResourceIDs[key] = identifier
        return baseURL
            .appendingPathComponent("resource")
            .appendingPathComponent(identifier)
    }

    private func registerVirtual(_ data: Data, contentType: String, suffix: String) throws -> URL {
        guard let baseURL else { throw RelayError.listenerUnavailable }
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "") + suffix
        resources[identifier] = Resource(
            payload: .virtual(data, contentType: contentType),
            createdAt: Date()
        )
        return baseURL
            .appendingPathComponent("resource")
            .appendingPathComponent(identifier)
    }

    private func pruneExpiredResources(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-2 * 60 * 60)
        let expired = Set(
            resources.compactMap { key, resource in
                resource.createdAt < cutoff ? key : nil
            }
        )
        guard !expired.isEmpty else { return }
        resources = resources.filter { !expired.contains($0.key) }
        upstreamResourceIDs = upstreamResourceIDs.filter {
            !expired.contains($0.value)
        }
    }

    // MARK: - Synthetic fMP4 HLS

    private func buildSyntheticHLS(
        formats: [VideoFormat],
        headers: [String: String]
    ) async throws -> URL {
        let videoCandidates = Self.bestVideoCandidates(from: formats)
        guard !videoCandidates.isEmpty,
              let audioCandidate = Self.bestAudioCandidate(from: formats),
              let audioURL = audioCandidate.url else {
            throw RelayError.noPlayableStreams
        }

        let capturedSession = session
        async let audioIndex = Self.loadMP4Index(
            url: audioURL,
            headers: headers,
            session: capturedSession
        )

        let indexedVideos = await withTaskGroup(of: IndexedFormat?.self) { group in
            for format in videoCandidates {
                guard let url = format.url else { continue }
                group.addTask {
                    guard let index = try? await Self.loadMP4Index(
                        url: url,
                        headers: headers,
                        session: capturedSession
                    ) else { return nil }
                    return IndexedFormat(format: format, index: index)
                }
            }

            var result: [IndexedFormat] = []
            for await indexed in group {
                if let indexed { result.append(indexed) }
            }
            return result.sorted {
                if $0.format.height != $1.format.height {
                    return $0.format.height < $1.format.height
                }
                return $0.format.fps < $1.format.fps
            }
        }

        let resolvedAudioIndex = try await audioIndex
        guard !indexedVideos.isEmpty else { throw RelayError.invalidMP4Index }

        let localAudioMedia = try registerUpstream(
            audioURL,
            headers: headers,
            requiresRange: true,
            preferredSuffix: ".m4a"
        )
        let audioPlaylist = Self.mediaPlaylist(
            mediaURL: localAudioMedia,
            index: resolvedAudioIndex
        )
        let localAudioPlaylist = try registerVirtual(
            Data(audioPlaylist.utf8),
            contentType: "application/vnd.apple.mpegurl",
            suffix: ".m3u8"
        )

        var videoEntries: [(format: VideoFormat, playlistURL: URL)] = []
        for indexed in indexedVideos {
            guard let remoteURL = indexed.format.url else { continue }
            let localMedia = try registerUpstream(
                remoteURL,
                headers: headers,
                requiresRange: true,
                preferredSuffix: ".mp4"
            )
            let playlist = Self.mediaPlaylist(
                mediaURL: localMedia,
                index: indexed.index
            )
            let localPlaylist = try registerVirtual(
                Data(playlist.utf8),
                contentType: "application/vnd.apple.mpegurl",
                suffix: ".m3u8"
            )
            videoEntries.append((indexed.format, localPlaylist))
        }

        let audioCodec = Self.codec(from: audioCandidate.mimeType, fallback: "mp4a.40.2")
        let audioBitrate = max(1, audioCandidate.bitrate ?? 128_000)
        var master = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Original\",LANGUAGE=\"und\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(localAudioPlaylist.absoluteString)\"",
        ]

        for entry in videoEntries {
            let format = entry.format
            let bandwidth = max(1, (format.bitrate ?? 1) + audioBitrate)
            let videoCodec = Self.codec(from: format.mimeType, fallback: "avc1.4d401f")
            master.append(
                "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),AVERAGE-BANDWIDTH=\(bandwidth),CODECS=\"\(videoCodec),\(audioCodec)\",RESOLUTION=\(format.width)x\(format.height),FRAME-RATE=\(format.fps),AUDIO=\"audio\""
            )
            master.append(entry.playlistURL.absoluteString)
        }

        return try registerVirtual(
            Data((master.joined(separator: "\n") + "\n").utf8),
            contentType: "application/vnd.apple.mpegurl",
            suffix: ".m3u8"
        )
    }

    private static func bestVideoCandidates(from formats: [VideoFormat]) -> [VideoFormat] {
        let compatible = formats.filter {
            $0.url != nil
                && $0.height > 0
                && $0.height <= InnerTubeClients.VisionOS.maximumHLSHeight
                && $0.mimeType.hasPrefix("video/mp4")
                && $0.mimeType.contains("avc1")
                && !$0.mimeType.contains(", ")
        }
        var bestByTier: [String: VideoFormat] = [:]
        for format in compatible {
            let key = "\(format.height)-\(format.fps)"
            if let current = bestByTier[key],
               (current.bitrate ?? 0) >= (format.bitrate ?? 0) {
                continue
            }
            bestByTier[key] = format
        }
        return bestByTier.values.sorted {
            if $0.height != $1.height { return $0.height < $1.height }
            return $0.fps < $1.fps
        }
    }

    private static func bestAudioCandidate(from formats: [VideoFormat]) -> VideoFormat? {
        formats
            .filter { $0.url != nil && $0.mimeType.hasPrefix("audio/mp4") }
            .max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
    }

    private static func loadMP4Index(
        url: URL,
        headers: [String: String],
        session: URLSession
    ) async throws -> MP4Index {
        try validateUpstream(url)
        var lastError: Error = RelayError.invalidMP4Index

        for byteCount in [65_536, 262_144, 1_048_576] {
            var request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 15
            )
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
            request.setValue("bytes=0-\(byteCount - 1)", forHTTPHeaderField: "Range")

            let itag = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "itag" })?.value ?? "unknown"
            let response: IPv4HTTPResponse
            do {
                response = try await fetchUpstream(request, session: session)
            } catch {
                diagnosticLog("index itag=\(itag) transport failed: \(error.localizedDescription)")
                lastError = error
                continue
            }
            diagnosticLog(
                "index itag=\(itag) status=\(response.statusCode) bytes=\(response.body.count) requested=\(byteCount)"
            )
            guard response.statusCode == 200 || response.statusCode == 206 else {
                // A larger byte range cannot turn an authorization failure into a
                // valid response. Return immediately so the working relay fallback
                // starts without three identical CDN requests per track.
                throw RelayError.upstreamFailed("MP4 index probe was rejected with HTTP \(response.statusCode)")
            }
            do {
                return try parseMP4Index(response.body)
            } catch {
                diagnosticLog("index itag=\(itag) parse failed: \(error.localizedDescription)")
                lastError = error
            }
        }
        throw lastError
    }

    static func parseMP4Index(_ data: Data) throws -> MP4Index {
        var boxOffset = 0
        while boxOffset + 8 <= data.count {
            guard let size32 = data.uint32BE(at: boxOffset) else {
                throw RelayError.invalidMP4Index
            }
            let typeData = data[(boxOffset + 4)..<(boxOffset + 8)]
            let type = String(decoding: typeData, as: UTF8.self)
            var boxSize = Int64(size32)
            var headerSize = 8

            if size32 == 1 {
                guard let extended = data.uint64BE(at: boxOffset + 8) else {
                    throw RelayError.invalidMP4Index
                }
                boxSize = Int64(extended)
                headerSize = 16
            }
            guard boxSize >= Int64(headerSize), boxSize <= Int64(Int.max) else {
                throw RelayError.invalidMP4Index
            }

            if type != "sidx" {
                let next = Int64(boxOffset) + boxSize
                guard next <= Int64(data.count) else { break }
                boxOffset = Int(next)
                continue
            }

            let boxEnd64 = Int64(boxOffset) + boxSize
            guard boxEnd64 <= Int64(data.count) else {
                throw RelayError.invalidMP4Index
            }
            let boxEnd = Int(boxEnd64)
            var cursor = boxOffset + headerSize
            guard cursor + 12 <= boxEnd else { throw RelayError.invalidMP4Index }

            let version = data[cursor]
            cursor += 4 // version + flags
            cursor += 4 // reference_ID
            guard let timescaleValue = data.uint32BE(at: cursor), timescaleValue > 0 else {
                throw RelayError.invalidMP4Index
            }
            let timescale = Double(timescaleValue)
            cursor += 4

            let firstOffset: UInt64
            if version == 0 {
                guard let value = data.uint32BE(at: cursor + 4) else {
                    throw RelayError.invalidMP4Index
                }
                firstOffset = UInt64(value)
                cursor += 8
            } else {
                guard let value = data.uint64BE(at: cursor + 8) else {
                    throw RelayError.invalidMP4Index
                }
                firstOffset = value
                cursor += 16
            }

            guard let referenceCount = data.uint16BE(at: cursor + 2) else {
                throw RelayError.invalidMP4Index
            }
            cursor += 4 // reserved + reference_count

            var mediaOffset = UInt64(boxOffset) + UInt64(boxSize) + firstOffset
            var references: [MP4Index.Reference] = []
            references.reserveCapacity(Int(referenceCount))

            for _ in 0..<referenceCount {
                guard cursor + 12 <= boxEnd,
                      let typeAndSize = data.uint32BE(at: cursor),
                      let duration = data.uint32BE(at: cursor + 4) else {
                    throw RelayError.invalidMP4Index
                }
                let referenceType = typeAndSize >> 31
                let referencedSize = UInt64(typeAndSize & 0x7fff_ffff)
                guard referenceType == 0,
                      referencedSize > 0,
                      mediaOffset <= UInt64(Int64.max),
                      referencedSize <= UInt64(Int64.max) else {
                    throw RelayError.invalidMP4Index
                }
                references.append(
                    MP4Index.Reference(
                        offset: Int64(mediaOffset),
                        size: Int64(referencedSize),
                        duration: Double(duration) / timescale
                    )
                )
                mediaOffset += referencedSize
                cursor += 12
            }

            guard boxOffset > 0, !references.isEmpty else {
                throw RelayError.invalidMP4Index
            }
            return MP4Index(
                initializationLength: Int64(boxOffset),
                references: references
            )
        }
        throw RelayError.invalidMP4Index
    }

    static func mediaPlaylist(mediaURL: URL, index: MP4Index) -> String {
        let targetDuration = max(
            1,
            Int(ceil(index.references.map(\.duration).max() ?? 1))
        )
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-MAP:URI=\"\(mediaURL.absoluteString)\",BYTERANGE=\"\(index.initializationLength)@0\"",
        ]
        for reference in index.references {
            lines.append("#EXTINF:\(String(format: "%.6f", reference.duration)),")
            lines.append("#EXT-X-BYTERANGE:\(reference.size)@\(reference.offset)")
            lines.append(mediaURL.absoluteString)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Pure helpers (covered by unit tests)

    static let maximumRangeBytes = 16 * 1024 * 1024

    static func boundedRange(
        _ value: String,
        maximumBytes: Int = maximumRangeBytes
    ) -> String? {
        let pattern = #"^bytes=(\d+)-(\d*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              let startRange = Range(match.range(at: 1), in: value),
              let start = Int64(value[startRange]),
              start >= 0 else { return nil }

        let requestedEnd: Int64
        if let endRange = Range(match.range(at: 2), in: value),
           !value[endRange].isEmpty,
           let parsed = Int64(value[endRange]),
           parsed >= start {
            requestedEnd = parsed
        } else {
            requestedEnd = Int64.max
        }
        let cappedEnd = min(
            requestedEnd,
            start + Int64(maximumBytes) - 1
        )
        return "bytes=\(start)-\(cappedEnd)"
    }

    static func rewritePlaylist(
        _ manifest: String,
        baseURL: URL,
        localURLFor: (URL) throws -> URL
    ) rethrows -> String {
        let attributeRegex = try? NSRegularExpression(pattern: #"URI=\"([^\"]+)\""#)
        var output: [String] = []

        for rawLine in manifest.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("#"),
               let upstream = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL {
                output.append(try localURLFor(upstream).absoluteString)
                continue
            }

            var line = rawLine
            if let attributeRegex {
                let matches = attributeRegex.matches(
                    in: line,
                    range: NSRange(line.startIndex..., in: line)
                )
                for match in matches.reversed() {
                    guard let valueRange = Range(match.range(at: 1), in: line),
                          let upstream = URL(
                            string: String(line[valueRange]),
                            relativeTo: baseURL
                          )?.absoluteURL else { continue }
                    line.replaceSubrange(
                        valueRange,
                        with: try localURLFor(upstream).absoluteString
                    )
                }
            }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    private static func isPlaylist(data: Data, contentType: String, url: URL) -> Bool {
        let lowered = contentType.lowercased()
        if lowered.contains("mpegurl") || lowered.contains("m3u") { return true }
        if url.pathExtension.lowercased() == "m3u8" { return true }
        return data.starts(with: Data("#EXTM3U".utf8))
    }

    private static func codec(from mimeType: String, fallback: String) -> String {
        guard let range = mimeType.range(
            of: #"codecs=\"([^\"]+)\""#,
            options: .regularExpression
        ) else { return fallback }
        let match = String(mimeType[range])
        guard let firstQuote = match.firstIndex(of: "\""),
              let lastQuote = match.lastIndex(of: "\""),
              firstQuote < lastQuote else { return fallback }
        return String(match[match.index(after: firstQuote)..<lastQuote])
    }

    private static func preferredSuffix(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, ext.count <= 8,
           ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return ".\(ext)"
        }
        if url.absoluteString.contains("m3u8") { return ".m3u8" }
        return ""
    }

    private static func validateUpstream(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            throw RelayError.invalidUpstreamHost(url.host ?? "missing")
        }
        let allowed = host == "youtube.com"
            || host.hasSuffix(".youtube.com")
            || host == "googlevideo.com"
            || host.hasSuffix(".googlevideo.com")
        guard allowed else { throw RelayError.invalidUpstreamHost(host) }
    }
}

// MARK: - Minimal loopback HTTP/1.1 connection

fileprivate struct RelayHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]

    init?(headerData: Data) {
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        method = String(parts[0]).uppercased()
        let target = String(parts[1])
        path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? target

        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            parsedHeaders[name] = value
        }
        headers = parsedHeaders
    }
}

fileprivate struct RelayHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    static func text(status: Int, _ message: String) -> RelayHTTPResponse {
        let data = Data(message.utf8)
        return RelayHTTPResponse(
            status: status,
            headers: [
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Length": String(data.count),
                "Cache-Control": "no-store",
            ],
            body: data
        )
    }
}

fileprivate final class LoopbackHTTPConnection: @unchecked Sendable {
    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let maximumHeaderBytes = 64 * 1024

    private let connection: NWConnection
    private let relay: OnDevicePlaybackRelay
    private var received = Data()
    private var didStartReceiving = false

    init(connection: NWConnection, relay: OnDevicePlaybackRelay) {
        self.connection = connection
        self.relay = relay
    }

    func start(on queue: DispatchQueue) {
        // NWListener does not retain this wrapper. The callback deliberately keeps
        // it alive until the request finishes, then `finish()` breaks the cycle.
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                guard !didStartReceiving else { return }
                didStartReceiving = true
                receiveNext()
            case .failed(_), .cancelled:
                finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveNext() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16 * 1024
        ) { [self] content, _, isComplete, error in
            if let content { received.append(content) }
            if received.count > Self.maximumHeaderBytes {
                send(.text(status: 431, "Request Header Fields Too Large"))
                return
            }
            if let terminator = received.range(of: Self.headerTerminator) {
                let headerData = received[..<terminator.upperBound]
                guard let request = RelayHTTPRequest(headerData: Data(headerData)) else {
                    send(.text(status: 400, "Bad Request"))
                    return
                }
                Task { [self] in
                    let response = await relay.response(for: request)
                    send(response, omitBody: request.method == "HEAD")
                }
                return
            }
            if error != nil || isComplete {
                send(.text(status: 400, "Incomplete Request"))
                return
            }
            receiveNext()
        }
    }

    private func send(_ response: RelayHTTPResponse, omitBody: Bool = false) {
        let reason = Self.reasonPhrase(for: response.status)
        var headers = response.headers
        headers["Connection"] = "close"
        headers["Server"] = "iTube-OnDevice"
        if headers["Content-Length"] == nil {
            headers["Content-Length"] = String(response.body.count)
        }

        var wire = Data("HTTP/1.1 \(response.status) \(reason)\r\n".utf8)
        for key in headers.keys.sorted() {
            wire.append(Data("\(key): \(headers[key] ?? "")\r\n".utf8))
        }
        wire.append(Data("\r\n".utf8))
        if !omitBody { wire.append(response.body) }

        connection.send(
            content: wire,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [self] _ in
                finish()
            }
        )
    }

    private func finish() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 416: return "Range Not Satisfiable"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "HTTP Response"
        }
    }
}

private extension Data {
    func uint16BE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return self[offset..<(offset + 2)].reduce(UInt16(0)) {
            ($0 << 8) | UInt16($1)
        }
    }

    func uint32BE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return self[offset..<(offset + 4)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }

    func uint64BE(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        return self[offset..<(offset + 8)].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
    }
}
