import SwiftUI
import SmartTubeIOSCore
import os

#if os(tvOS)
import CoreImage
#endif

private let focusLog = Logger(subsystem: "com.smarttube", category: "focus")
private let feedLog  = Logger(subsystem: "com.smarttube", category: "feed")

#if os(tvOS)
/// A small, Sendable color payload derived from the lower part of a thumbnail.
/// Keeping platform colors out of the cache makes this safe under Swift 6's
/// strict concurrency checking.
private struct VideoCardTone: Sendable, Equatable {
    let red: Double
    let green: Double
    let blue: Double

    static let fallback = VideoCardTone(red: 0.055, green: 0.06, blue: 0.075)

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    var focusGlow: Color {
        Color(
            red: min(red * 1.7 + 0.08, 1),
            green: min(green * 1.7 + 0.08, 1),
            blue: min(blue * 1.7 + 0.08, 1)
        )
    }
}

/// Coalesces artwork work across cards. Home shelves frequently repeat channels,
/// so this prevents duplicate avatar requests and repeated palette extraction.
private actor VideoCardArtworkCache {
    static let shared = VideoCardArtworkCache()

    private var tones: [URL: VideoCardTone] = [:]
    private var toneTasks: [URL: Task<VideoCardTone, Never>] = [:]
    private var avatarURLs: [String: URL] = [:]
    private var missingAvatars: Set<String> = []
    private var avatarTasks: [String: Task<URL?, Never>] = [:]

    func tone(for url: URL) async -> VideoCardTone {
        if let cached = tones[url] { return cached }
        if let task = toneTasks[url] { return await task.value }

        let task = Task { await Self.loadTone(from: url) }
        toneTasks[url] = task
        let tone = await task.value
        tones[url] = tone
        toneTasks[url] = nil
        return tone
    }

    func avatarURL(for channelID: String, api: InnerTubeAPI) async -> URL? {
        if let cached = avatarURLs[channelID] { return cached }
        if missingAvatars.contains(channelID) { return nil }
        if let task = avatarTasks[channelID] { return await task.value }

        let task = Task<URL?, Never> {
            try? await api.fetchChannelThumbnailURL(channelId: channelID)
        }
        avatarTasks[channelID] = task
        let url = await task.value
        avatarTasks[channelID] = nil
        if let url {
            avatarURLs[channelID] = url
        } else {
            missingAvatars.insert(channelID)
        }
        return url
    }

    private static func loadTone(from url: URL) async -> VideoCardTone {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .fallback
            }
            guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                return .fallback
            }

            // The card fades from the actual lower portion of the artwork, so the
            // transition looks authored instead of like a generic black overlay.
            let extent = image.extent
            let sampleRect = CGRect(
                x: extent.minX,
                y: extent.minY,
                width: extent.width,
                height: max(extent.height * 0.42, 1)
            )
            guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: image,
                kCIInputExtentKey: CIVector(cgRect: sampleRect),
            ]), let output = filter.outputImage else {
                return .fallback
            }

            var rgba = [UInt8](repeating: 0, count: 4)
            let context = CIContext(options: [.workingColorSpace: NSNull()])
            context.render(
                output,
                toBitmap: &rgba,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
            return darkenedTone(
                red: Double(rgba[0]) / 255,
                green: Double(rgba[1]) / 255,
                blue: Double(rgba[2]) / 255
            )
        } catch {
            return .fallback
        }
    }

    /// Preserve the thumbnail hue while keeping white metadata readable.
    private static func darkenedTone(red: Double, green: Double, blue: Double) -> VideoCardTone {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        let saturation = maximum == 0 ? 0 : delta / maximum

        var hue = 0.0
        if delta > 0 {
            if maximum == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == green {
                hue = ((blue - red) / delta) + 2
            } else {
                hue = ((red - green) / delta) + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }

        let adjustedSaturation = saturation < 0.08
            ? 0
            : min(max(saturation * 1.05, 0.2), 0.78)
        let adjustedBrightness = min(max(maximum * 0.46, 0.075), 0.34)
        return rgbTone(hue: hue, saturation: adjustedSaturation, brightness: adjustedBrightness)
    }

    private static func rgbTone(hue: Double, saturation: Double, brightness: Double) -> VideoCardTone {
        guard saturation > 0 else {
            return VideoCardTone(red: brightness, green: brightness, blue: brightness)
        }
        let sector = hue * 6
        let index = Int(floor(sector)) % 6
        let fraction = sector - floor(sector)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - fraction * saturation)
        let t = brightness * (1 - (1 - fraction) * saturation)
        switch index {
        case 0: return VideoCardTone(red: brightness, green: t, blue: p)
        case 1: return VideoCardTone(red: q, green: brightness, blue: p)
        case 2: return VideoCardTone(red: p, green: brightness, blue: t)
        case 3: return VideoCardTone(red: p, green: q, blue: brightness)
        case 4: return VideoCardTone(red: t, green: p, blue: brightness)
        default: return VideoCardTone(red: brightness, green: p, blue: q)
        }
    }
}
#endif

// MARK: - Notification names

extension Notification.Name {
    /// Posted when the user selects "Open Channel" from a video's context menu.
    /// userInfo keys: "channelId", "channelTitle"
    static let openChannel = Notification.Name("com.smarttube.openChannel")
    /// Posted when a feature requests navigation to the Search tab (e.g. empty-state CTA).
    static let navigateToSearch = Notification.Name("com.smarttube.navigateToSearch")
    // hideVideoFromFeed and hideChannelFromFeed are defined in SmartTubeIOSCore/FeedFeedbackNotifications.swift
}

// MARK: - VideoCardView
//
// A card showing a video thumbnail, title, channel and metadata.
// Adapts its layout for list (compact) and grid (default) modes.

public struct VideoCardView: View {
    public let video: Video
    public var compact: Bool = false
    /// When set, this is the `playlistId` of the list the user is currently browsing.
    /// Pass `"WL"` when inside the Watch Later playlist so the context menu shows
    /// "Remove from Watch Later" instead of "Save to Watch Later".
    public var currentPlaylistId: String? = nil
    /// Called when the user taps/selects the card on tvOS (via `.onTapGesture`).
    /// iOS call sites continue using their own tap handlers; this is only invoked
    /// from the `#else` (tvOS) modifier block below.
    public var onSelect: (() -> Void)? = nil

    @Environment(AuthService.self) private var authService
    @Environment(SettingsStore.self) private var store
    @Environment(\.innerTubeAPI) private var api
    @State private var localProgress: Double?
    @State private var watchLaterAlert: DownloadAlertItem?
    /// Index into `video.thumbnailFallbackURLs`. -1 = use primary `thumbnailURL`.
    @State private var thumbnailFallbackIndex: Int = -1
    #if !os(tvOS)
    @Environment(VideoDownloadService.self) private var downloadService
    #endif
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .caption) private var cardTitleSize: CGFloat = 20
    @ScaledMetric(relativeTo: .caption2) private var channelNameSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var metadataSize: CGFloat = 13
    @State private var artworkTone: VideoCardTone = .fallback
    @State private var channelAvatarURL: URL?
    #endif

    private var effectiveProgress: Double? {
        localProgress ?? video.watchProgress
    }

    public init(video: Video, compact: Bool = false, currentPlaylistId: String? = nil, onSelect: (() -> Void)? = nil) {
        self.video = video
        self.compact = compact
        self.currentPlaylistId = currentPlaylistId
        self.onSelect = onSelect
    }

    // MARK: - Shared card content (tasks + context menu)
    // Extracted so the tvOS body can wrap it in a Button (which handles the
    // Select button press natively) while iOS continues using the bare view.

    private var cardContent: some View {
        Group {
            #if os(tvOS)
            tvCardLayout
            #else
            if compact {
                compactLayout
            } else {
                gridLayout
            }
            #endif
        }
        .task {
            localProgress = await VideoStateStore.shared.state(for: video.id)?.watchedFraction
        }
        .task(id: video.id) {
            await VideoPreloadCache.shared.prefetch(
                videoId: video.id,
                sponsorCategories: store.settings.activeSponsorCategories,
                authToken: authService.accessToken,
                priority: .visible
            )
            // Pre-warm BotGuardWebViewRunner when cards scroll into view so the
            // WKWebView youtube.com context is ready before the user taps. Only
            // runs once — isReady short-circuits all subsequent calls (~0ms).
            // fix16: Await BotGuard BEFORE preWarm so its SOCS cookie is in the shared
            // .default() WKWebView data store before extractHLSURL creates its WKWebView.
            // Without this, uN7uKLsGRWw (rqh=1) hits a GDPR redirect on a cold data store
            // and times out at 40 s. With the SOCS cookie already set, extraction is ~2 s.
            // BotGuard.prepare() is idempotent (no-op if already ready, or coalescences with
            // an ongoing task), so all card tasks joining the same prepare() call pay ≤8 s
            // total — not per-card.
            #if canImport(WebKit)
            await BotGuardWebViewRunner.shared.prepare()
            // iOS uses TOS player (WKWebView embed) by default — HLS URLs are never
            // consumed there, so pre-warming the HLS extractor is pure waste and the
            // primary source of the SlowLoad NON_FATAL (4497ms per card on scroll).
            // Mac/tvOS still use AVPlayer and need the pre-warm.
            #if !os(iOS)
            if !video.isShort &&
               YouTubeWebViewHLSExtractor.activePreWarmLoops < YouTubeWebViewHLSExtractor.maxPreWarmLoops {
                YouTubeWebViewHLSExtractor.activePreWarmLoops += 1
                defer { YouTubeWebViewHLSExtractor.activePreWarmLoops -= 1 }
                let videoId = video.id
                outer: while !Task.isCancelled {
                    if await VideoPreloadCache.shared.cachedWKHLSURL(for: videoId) == nil {
                        await YouTubeWebViewHLSExtractor.preWarm(videoId: videoId)
                    }
                    let hasCachedURL = await VideoPreloadCache.shared.cachedWKHLSURL(for: videoId) != nil
                    let hasCachedPot = await VideoPreloadCache.shared.cachedPoToken(for: videoId) != nil
                    if hasCachedURL && !hasCachedPot && !YouTubeWebViewHLSExtractor.isPreWarming {
                        YouTubeWebViewHLSExtractor.isPreWarming = true
                        if let freshURL = await YouTubeWebViewHLSExtractor.shared.serialExtract(videoId: videoId) {
                            let freshPot = YouTubeWebViewHLSExtractor.shared.extractedPoToken
                            await VideoPreloadCache.shared.store(wkHLSManifestURL: freshURL, for: videoId, isPreWarm: true)
                            if let pot = freshPot {
                                await VideoPreloadCache.shared.store(wkHLSPoToken: pot, for: videoId)
                            }
                        }
                        YouTubeWebViewHLSExtractor.isPreWarming = false
                    }
                    CFNotificationCenterPostNotification(
                        CFNotificationCenterGetDarwinNotifyCenter(),
                        CFNotificationName("com.void.smarttube.player.prewarm.done.\(videoId)" as CFString),
                        nil, nil, true
                    )
                    do {
                        try await Task.sleep(nanoseconds: 30_000_000_000)
                    } catch {
                        break outer
                    }
                    let stillCached = await VideoPreloadCache.shared.cachedWKHLSURL(for: videoId) != nil
                    if stillCached { break outer }
                }
            }
            #endif
            #endif
        }
        #if os(tvOS)
        .task(id: activeThumbnailURL) {
            guard let url = activeThumbnailURL else {
                artworkTone = .fallback
                return
            }
            artworkTone = await VideoCardArtworkCache.shared.tone(for: url)
        }
        .task(id: video.channelId) {
            guard let channelID = video.channelId, !channelID.isEmpty else {
                channelAvatarURL = nil
                return
            }
            channelAvatarURL = await VideoCardArtworkCache.shared.avatarURL(for: channelID, api: api)
        }
        #endif
        .contextMenu {
            #if !os(tvOS)
            if let shareURL = URL(string: "https://www.youtube.com/watch?v=\(video.id)") {
                ShareLink(item: shareURL) {
                    Label("Share", systemImage: AppSymbol.share)
                }
            }
            #endif
            if let channelId = video.channelId, !channelId.isEmpty {
                Button {
                    NotificationCenter.default.post(
                        name: .openChannel,
                        object: nil,
                        userInfo: ["channelId": channelId, "channelTitle": video.channelTitle]
                    )
                } label: {
                    Label("Open Channel", systemImage: AppSymbol.personRectangle)
                }
            }
            if authService.isSignedIn {
                if currentPlaylistId == "WL" {
                    Button(role: .destructive) {
                        Task {
                            do {
                                try await api.removeFromWatchLater(videoId: video.id)
                                watchLaterAlert = DownloadAlertItem(
                                    title: String(localized: "Removed from Watch Later", bundle: .module),
                                    message: String(localized: "\"\(video.title)\" was removed from your Watch Later playlist.", bundle: .module)
                                )
                            } catch {
                                watchLaterAlert = DownloadAlertItem(
                                    title: String(localized: "Could Not Remove", bundle: .module),
                                    message: error.localizedDescription
                                )
                            }
                        }
                    } label: {
                        Label("Remove from Watch Later", systemImage: AppSymbol.watchLater)
                    }
                } else {
                    Button {
                        Task {
                            do {
                                try await api.addToWatchLater(videoId: video.id)
                                watchLaterAlert = DownloadAlertItem(
                                    title: String(localized: "Saved to Watch Later", bundle: .module),
                                    message: String(localized: "\"\(video.title)\" was added to your Watch Later playlist.", bundle: .module)
                                )
                            } catch {
                                watchLaterAlert = DownloadAlertItem(
                                    title: String(localized: "Could Not Save", bundle: .module),
                                    message: error.localizedDescription
                                )
                            }
                        }
                    } label: {
                        Label("Save to Watch Later", systemImage: AppSymbol.watchLater)
                    }
                }
            }
            Button {
                Task { await CurrentQueueStore.shared.append(video) }
            } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }
            Button {
                Task {
                    let count = await CurrentQueueStore.shared.videos.count
                    await CurrentQueueStore.shared.insertNext(video, afterIndex: count - 1)
                }
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            if authService.isSignedIn {
                Button(role: .destructive) {
                    Task {
                        if let token = video.notInterestedToken {
                            try? await api.sendFeedback(token: token)
                        } else {
                            try? await api.sendFeedbackForVideo(videoId: video.id, iconType: "NOT_INTERESTED")
                        }
                        NotificationCenter.default.post(
                            name: .hideVideoFromFeed,
                            object: nil,
                            userInfo: ["videoId": video.id]
                        )
                    }
                } label: {
                    Label("Not Interested", systemImage: "hand.raised")
                }
                if let channelId = video.channelId, !channelId.isEmpty {
                    Button(role: .destructive) {
                        Task {
                            if let token = video.hideChannelToken {
                                try? await api.sendFeedback(token: token)
                            } else {
                                try? await api.sendFeedbackForVideo(videoId: video.id, iconType: "BLOCK_CHANNEL")
                            }
                            store.settings.blockedChannels[channelId] = video.channelTitle
                            NotificationCenter.default.post(
                                name: .hideChannelFromFeed,
                                object: nil,
                                userInfo: ["channelId": channelId]
                            )
                        }
                    } label: {
                        Label("Don't Recommend Channel", systemImage: "person.slash")
                    }
                }
            }
            #if !os(tvOS)
            Button {
                downloadService.download(video: video)
            } label: {
                if downloadService.state.isActive {
                    Label("Downloading…", systemImage: AppSymbol.download)
                } else {
                    Label("Download to Gallery", systemImage: AppSymbol.download)
                }
            }
            .disabled(downloadService.state.isActive)
            #endif
        } preview: {
            Group {
                if compact {
                    compactLayout
                } else {
                    gridLayout
                }
            }
            .padding(12)
            .frame(width: 300)
            .background(.background)
        }
        #if !os(tvOS)
        // Download state is observed at app-root level (RootView) so the alert
        // survives context menu dismiss animations that would otherwise reset
        // the card-level @State. Only the button label/disabled state is read here.
        .padding(0)  // zero-effect modifier to keep the view chain well-typed
        #endif
    }

    // MARK: - Body

    public var body: some View {
        #if os(tvOS)
        // Modifier order is critical on tvOS:
        //
        //   cardContent  (contains .contextMenu — handles long press)
        //       .focusable()          — registers view with focus engine (D-pad navigation)
        //       .onTapGesture { }     — fires on Select press (outermost → receives event first)
        //       .focused($isFocused)  — tracks focus state (does not consume events)
        //
        // Why this order works:
        // • .onTapGesture outermost → Select button press fires the action.
        //   (.focusable() outermost broke Select because the focus engine intercepted
        //    the primary-action event before the inner tap gesture could see it.)
        // • .contextMenu innermost, co-located in the same modifier chain as
        //   .onTapGesture → SwiftUI's gesture arbiter can cancel the pending tap
        //   recogniser when it detects a long press, so long press shows the menu
        //   without also playing the video.
        // • .focusable() between contextMenu and onTapGesture keeps the view in the
        //   focus engine so D-pad UP/DOWN can reach it.
        cardContent
            .focusable()
            .onTapGesture { onSelect?() }
            .focused($isFocused)
            .onAppear { feedLog.info("[feed] id=\(self.video.id) title=\(self.video.title)") }
            .onChange(of: isFocused) { _, newValue in
                focusLog.info("[VideoCard] isFocused=\(newValue) id=\(self.video.id)")
                #if canImport(WebKit)
                if newValue, !video.isShort {
                    let videoId = video.id
                    Task(priority: .background) {
                        await YouTubeWebViewHLSExtractor.preWarm(videoId: videoId)
                    }
                }
                #endif
            }
            .shadow(
                color: isFocused ? artworkTone.focusGlow.opacity(0.52) : .black.opacity(0.2),
                radius: isFocused ? 30 : 12,
                x: 0,
                y: isFocused ? 12 : 7
            )
            .shadow(color: isFocused ? .white.opacity(0.24) : .clear, radius: 5, x: 0, y: 0)
            .scaleEffect(isFocused && !reduceMotion ? 1.045 : 1.0)
            .zIndex(isFocused ? 1 : 0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 1.0),
                value: isFocused
            )
            .alert(item: $watchLaterAlert) { item in
                Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
            }
        #else
        cardContent
            .onAppear { feedLog.info("[feed] id=\(self.video.id) title=\(self.video.title)") }
            .alert(item: $watchLaterAlert) { item in
                Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
            }
        #endif
    }

    // MARK: Grid layout (default)

    #if os(tvOS)
    private var tvCardLayout: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        return ZStack(alignment: .bottomLeading) {
            thumbnailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            // A quiet top vignette protects badges without flattening the artwork.
            LinearGradient(
                colors: [.black.opacity(0.2), .clear],
                startPoint: .top,
                endPoint: .center
            )

            // The lower material inherits the artwork's tone, matching the way
            // Apple TV art cards carry their own color into the information area.
            LinearGradient(
                stops: [
                    .init(color: artworkTone.color.opacity(0), location: 0.25),
                    .init(color: artworkTone.color.opacity(0.34), location: 0.48),
                    .init(color: artworkTone.color.opacity(0.84), location: 0.73),
                    .init(color: artworkTone.color, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Side falloff keeps long localized titles readable over busy frames.
            LinearGradient(
                colors: [.black.opacity(0.3), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )

            VStack(alignment: .leading, spacing: 8) {
                Spacer(minLength: 0)

                Text(displayTitle)
                    .font(.system(size: cardTitleSize, weight: .semibold))
                    .tracking(-0.15)
                    .foregroundStyle(.white)
                    .lineLimit(2, reservesSpace: true)
                    .shadow(color: .black.opacity(0.38), radius: 5, y: 2)
                    .accessibilityIdentifier("video.card.title")

                HStack(spacing: 10) {
                    channelLogo

                    Text(video.channelTitle.isEmpty ? "Unknown channel" : video.channelTitle)
                        .font(.system(size: channelNameSize, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(1)
                        .accessibilityIdentifier("video.card.channelName")

                    Spacer(minLength: 12)

                    let duration = video.formattedDuration
                    if !duration.isEmpty {
                        tvMetadataBadge(duration)
                    }
                }

                if !tvMetadataText.isEmpty {
                    Text(tvMetadataText)
                        .font(.system(size: metadataSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 20)

            if video.isLive {
                tvLiveBadge
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if let progress = effectiveProgress, progress > 0 {
                watchProgressBar(progress)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(artworkTone.color)
        .clipShape(shape)
        .overlay {
            // Two restrained highlights create the polished glass edge from the
            // reference without turning the whole content card into a glass panel.
            shape.stroke(
                LinearGradient(
                    colors: [
                        .white.opacity(isFocused ? 0.82 : 0.48),
                        .white.opacity(isFocused ? 0.28 : 0.13),
                        .black.opacity(0.34),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: isFocused ? 2.2 : 1.15
            )
        }
        .overlay {
            shape
                .inset(by: 2)
                .stroke(.white.opacity(isFocused ? 0.14 : 0.065), lineWidth: 1)
        }
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cardAccessibilityLabel)
        .accessibilityHint("Play video")
    }

    private var channelLogo: some View {
        Group {
            if let channelAvatarURL {
                AsyncImage(url: channelAvatarURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        channelLogoPlaceholder
                    }
                }
            } else {
                channelLogoPlaceholder
            }
        }
        .frame(width: 34, height: 34)
        .background(.black.opacity(reduceTransparency ? 0.86 : 0.4), in: Circle())
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.44), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
    }

    private var channelLogoPlaceholder: some View {
        ZStack {
            artworkTone.color
            Text(channelInitial)
                .font(.system(size: metadataSize, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var channelInitial: String {
        video.channelTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .first
            .map { String($0).uppercased() } ?? "•"
    }

    private var tvMetadataText: String {
        var parts: [String] = []
        let views = video.formattedViewCount
        if !views.isEmpty { parts.append(views) }
        if let uploadDateLabel { parts.append(uploadDateLabel) }
        return parts.joined(separator: " • ")
    }

    @ViewBuilder
    private func tvMetadataBadge(_ text: String) -> some View {
        let label = Text(text)
            .font(.system(size: metadataSize, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        if #available(tvOS 26.0, *), !reduceTransparency {
            label.glassEffect(.regular, in: Capsule())
        } else {
            label.background(.black.opacity(0.76), in: Capsule())
        }
    }

    @ViewBuilder
    private var tvLiveBadge: some View {
        let label = Text("LIVE")
            .font(.system(size: metadataSize, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        if #available(tvOS 26.0, *), !reduceTransparency {
            label.glassEffect(.regular.tint(.red), in: Capsule())
        } else {
            label.background(.red, in: Capsule())
        }
    }

    private var cardAccessibilityLabel: String {
        [displayTitle, video.channelTitle, tvMetadataText]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
    #endif

    private var gridLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(thumbnailView.clipped())
                .overlay(alignment: .bottom) {
                    if let progress = effectiveProgress, progress > 0 {
                        watchProgressBar(progress)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    let dur = video.formattedDuration
                    if !dur.isEmpty { durationBadge(dur) }
                }
                .overlay(alignment: .bottomLeading) {
                    if let label = uploadDateLabel { durationBadge(label) }
                }
                .overlay(alignment: .topLeading) {
                    if video.isLive { liveBadge }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    #if os(tvOS)
                    .font(.footnote.weight(.medium))
                    #else
                    .font(.subheadline.weight(.medium))
                    #endif
                    .lineLimit(2, reservesSpace: true)
                    .accessibilityIdentifier("video.card.title")
                Text(video.channelTitle)
                    #if os(tvOS)
                    .font(.caption2)
                    #else
                    .font(.caption)
                    #endif
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .onTapGesture {
                        guard let channelId = video.channelId, !channelId.isEmpty else { return }
                        NotificationCenter.default.post(
                            name: .openChannel,
                            object: nil,
                            userInfo: ["channelId": channelId, "channelTitle": video.channelTitle]
                        )
                    }
                    .accessibilityIdentifier("video.card.channelName")
                HStack(spacing: 4) {
                    let vc = video.formattedViewCount
                    if !vc.isEmpty { Text(vc) }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: Compact (list) layout

    private var compactLayout: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnailView
                .frame(width: 120, height: 68)
                .overlay(alignment: .bottom) {
                    if let progress = effectiveProgress, progress > 0 {
                        watchProgressBar(progress)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) {
                    let dur = video.formattedDuration
                    if !dur.isEmpty { durationBadge(dur) }
                }
                .overlay(alignment: .bottomLeading) {
                    if let label = uploadDateLabel { durationBadge(label) }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.subheadline)
                    .lineLimit(2)
                    .accessibilityIdentifier("video.card.title")
                Text(video.channelTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .onTapGesture {
                        guard let channelId = video.channelId, !channelId.isEmpty else { return }
                        NotificationCenter.default.post(
                            name: .openChannel,
                            object: nil,
                            userInfo: ["channelId": channelId, "channelTitle": video.channelTitle]
                        )
                    }
                    .accessibilityIdentifier("video.card.channelName")
                let vc = video.formattedViewCount
                if !vc.isEmpty {
                    Text(vc)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Shared

    /// Returns the DeArrow thumbnail URL if the feature is enabled and a timestamp is available.
    private var deArrowThumbnailURL: URL? {
        guard store.settings.deArrowEnabled,
              let ts = video.deArrowThumbnailTimestamp else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(video.id)/\(Int(ts)).jpg")
    }

    /// The title to show — community de-arrow title when enabled, raw title otherwise.
    private var displayTitle: String {
        if store.settings.deArrowEnabled, let t = video.deArrowTitle { return t }
        return video.title
    }

    private var activeThumbnailURL: URL? {
        let fallbacks = video.thumbnailFallbackURLs
        if thumbnailFallbackIndex < 0 {
            return deArrowThumbnailURL ?? video.thumbnailURL ?? fallbacks.first
        }
        return thumbnailFallbackIndex < fallbacks.count ? fallbacks[thumbnailFallbackIndex] : nil
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if video.thumbnailURL == nil, video.id == "WL" || video.id == "LL" {
            systemPlaylistThumbnail
        } else {
            // Walk a fallback chain on each successive failure:
            //   -1 → deArrowThumbnailURL (community thumbnail) or thumbnailURL (API-provided)
            //    0 → sddefault.jpg  (640×480, available for most videos)
            //    1 → hqdefault.jpg  (480×360, always available)
            //    2 → mqdefault.jpg  (320×180, always available — last resort)
            let fallbacks = video.thumbnailFallbackURLs
            AsyncImage(url: activeThumbnailURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure:
                    let nextIndex = thumbnailFallbackIndex + 1
                    if nextIndex < fallbacks.count {
                        placeholderThumbnail
                            .onAppear { thumbnailFallbackIndex = nextIndex }
                    } else {
                        placeholderThumbnail
                    }
                default:
                    placeholderThumbnail.overlay(ProgressView())
                }
            }
            .task(id: video.id) {
                // Reset so a reused card slot always tries the primary URL for the new video.
                thumbnailFallbackIndex = -1
                #if canImport(WebKit)
                await BotGuardWebViewRunner.shared.prepare()
                #if !os(iOS)
                if !video.isShort {
                    let videoId = video.id
                    while !Task.isCancelled {
                        await YouTubeWebViewHLSExtractor.preWarm(videoId: videoId)
                        if await VideoPreloadCache.shared.cachedWKHLSURL(for: videoId) != nil { break }
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                    }
                }
                #endif
                #endif
            }
        }
    }

    private var systemPlaylistThumbnail: some View {
        let icon = video.id == "WL" ? "clock.fill" : "hand.thumbsup.fill"
        return ZStack {
            Rectangle().fill(Color.secondary.opacity(0.15))
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.secondary)
        }
    }

    private var placeholderThumbnail: some View {
        Rectangle().fill(Color.secondary.opacity(0.2))
    }

    private func watchProgressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.black.opacity(0.3))
                Rectangle()
                    .fill(Color.red)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
    }

    private func durationBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.black.opacity(0.75))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .padding(4)
    }

    private var uploadDateLabel: String? {
        guard !video.isLive else { return nil }
        // Upcoming/scheduled: show when the stream starts instead of an upload date.
        if video.isUpcoming {
            guard let date = video.publishedAt else { return nil }
            let cal = Calendar.current
            let timeFmt = DateFormatter()
            timeFmt.locale = .autoupdatingCurrent
            timeFmt.timeStyle = .short
            if cal.isDateInToday(date) {
                return "Scheduled: Today, \(timeFmt.string(from: date))"
            }
            if cal.isDateInTomorrow(date) {
                return "Scheduled: Tomorrow, \(timeFmt.string(from: date))"
            }
            let dateFmt = DateFormatter()
            dateFmt.locale = .autoupdatingCurrent
            dateFmt.dateStyle = .medium
            dateFmt.timeStyle = .short
            return "Scheduled: \(dateFmt.string(from: date))"
        }
        guard let date = video.publishedAt else { return nil }
        let now = Date()
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 86_400 { return "Today" }
        let days = Int(elapsed / 86_400)
        // For recent videos (<7 days) always compute fresh relative label — avoids
        // showing a stale "2 hours ago" from a cached `publishedTimeText`.
        if days < 7 { return days == 1 ? "1 day ago" : "\(days) days ago" }
        // For older videos, prefer the raw API text (e.g. "2 years ago", "3 months ago").
        // Formatting an approximate publishedAt as "May 12" looks precise but can be weeks off.
        if let raw = video.publishedTimeText, !raw.isEmpty {
            let cleaned = raw.replacingOccurrences(
                of: #"^(Streamed|Premiered|Started)\s+"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty { return cleaned }
        }
        // Fallback: format the computed Date (exact for RSS feed videos, approximate for others).
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        return sameYear
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).year())
    }

    private var liveBadge: some View {
        Text("LIVE")
            .font(.caption2)
            .fontWeight(.bold)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.red)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .padding(4)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    VideoCardView(video: Video(
        id: "dQw4w9WgXcQ",
        title: "Rick Astley – Never Gonna Give You Up",
        channelTitle: "Rick Astley",
        duration: 213,
        viewCount: 1_400_000_000
    ))
    .frame(width: 320)
    .padding()
}
#endif
