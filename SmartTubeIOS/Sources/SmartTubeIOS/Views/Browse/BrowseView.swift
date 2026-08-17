import SwiftUI
import SmartTubeIOSCore

// MARK: - BrowseView
//
// Main home feed.  Mirrors the Android `BrowseFragment`.

public struct BrowseView: View {
    @Environment(BrowseViewModel.self) private var vm
    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var settings
    @Environment(\.innerTubeAPI) private var api
    @State private var selectedVideo: Video?
    @State private var selectedPlaylist: Video?
    @State private var channelDestination: ChannelDestination?
    @State private var showSignIn = false
    @State private var showError = false
    #if os(iOS)
    @Environment(PlayerRouter.self) private var playerRouter
    #endif

    public init() {}

    public var body: some View {
        Group {
            if vm.isLoading && vm.videoGroups.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.videoGroups.isEmpty && !vm.isLoading {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle(vm.currentSection.title)
        .toolbar { sectionPicker }
        #if !os(iOS) && !os(macOS)
        .fullScreenCover(item: $selectedVideo) { video in
            PlayerView(video: video, api: api)
        }
        #endif
        .navigationDestination(item: $selectedPlaylist) { stub in
            PlaylistView(playlistId: stub.id, playlistTitle: stub.title, api: api)
        }
        .navigationDestination(item: $channelDestination) { dest in
            ChannelView(channelId: dest.channelId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
            guard let channelId = note.userInfo?["channelId"] as? String, !channelId.isEmpty else { return }
            channelDestination = ChannelDestination(channelId: channelId)
        }
        .alert("Error", isPresented: $showError, presenting: vm.error) { _ in
            Button("Retry") { vm.loadContent(refresh: true) }
            Button("Dismiss", role: .cancel) { vm.error = nil }
        } message: { err in
            Text(err.localizedDescription)
        }
        .onChange(of: vm.error == nil ? 0 : 1) { _, hasError in
            if hasError == 1 { showError = true }
        }
        .sheet(isPresented: $showSignIn) { SignInView() }
        .onAppear {
            if vm.videoGroups.isEmpty { vm.loadContent() }
        }
        #if !os(tvOS)
        .refreshable { vm.loadContent(refresh: true) }
        #endif
    }

    // MARK: - Subviews

    private var content: some View {
        let allVideos: [Video] = vm.videoGroups
            .flatMap(\.videos)
            .filter { !$0.isShort }

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if vm.isAuthRequired && !auth.isSignedIn { guestBanner }
                VideoGridSection(
                    videos: allVideos,
                    onSelect: { selectVideo($0, from: allVideos) },
                    loadMore: {
                        if let last = allVideos.last {
                            vm.loadMoreIfNeeded(lastVideo: last)
                        }
                    }
                )
                .accessibilityIdentifier("browse.section")
                if vm.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
    }

    private func selectVideo(_ video: Video, from groupVideos: [Video]) {
        if vm.currentSection.type == .playlists {
            selectedPlaylist = video
        } else {
            #if os(iOS)
            playerRouter.open(video: video, api: api)
            #else
            selectedVideo = video
            #endif
        }
    }

    private var guestBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: AppSymbol.personCircle)
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in for your personal feed")
                    .font(.subheadline.weight(.semibold))
                Text("Showing popular videos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Sign In") { showSignIn = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        #if !os(tvOS)
        .background(.bar)
        #endif
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: vm.isAuthRequired ? AppSymbol.personCircleWarning : AppSymbol.tvPlay)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            if vm.isAuthRequired && !auth.isSignedIn {
                Text("Sign in to see your feed")
                    .font(.title3)
                Text("Your home feed, subscriptions and history\nrequire a Google account.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Sign In") { showSignIn = true }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Nothing here yet")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Button("Refresh") { vm.loadContent(refresh: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var sectionPicker: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Section", selection: Binding(
                get: { vm.currentSection },
                set: { vm.select(section: $0) }
            )) {
                ForEach(vm.sections) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }
}

// MARK: - VideoGridSection

#if os(tvOS)
/// Gives every cell an explicit 16:9 proposal. A plain flexible `HStack` first
/// measures `AsyncImage` at its 4:3 fallback size, which can make the whole row
/// too tall and expose the letterbox bars embedded in YouTube's fallback art.
private struct TVVideoGridRowLayout: Layout {
    let columnCount: Int
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let fallbackWidth = subviews.reduce(CGFloat.zero) { partial, subview in
            partial + subview.sizeThatFits(.unspecified).width
        } + spacing * CGFloat(max(0, columnCount - 1))
        let width = max(proposal.width ?? fallbackWidth, spacing * CGFloat(max(0, columnCount - 1)))
        return CGSize(width: width, height: cellWidth(for: width) * 9 / 16)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let width = cellWidth(for: bounds.width)
        let size = CGSize(width: width, height: width * 9 / 16)

        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(index) * (width + spacing), y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
        }
    }

    private func cellWidth(for totalWidth: CGFloat) -> CGFloat {
        let gaps = spacing * CGFloat(max(0, columnCount - 1))
        return max(0, (totalWidth - gaps) / CGFloat(columnCount))
    }
}
#endif

struct VideoGridSection: View {
    let videos: [Video]
    let onSelect: (Video) -> Void
    var loadMore: (() -> Void)? = nil
    #if os(tvOS)
    var restoreFocusedVideoID: String? = nil
    var onFocusRestored: ((String) -> Void)? = nil
    #endif

    @Environment(SettingsStore.self) private var store
    #if os(tvOS)
    @FocusState private var focusedVideoID: String?
    #endif
    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Rotated on every UIDevice orientation change so `.id(orientationToken)` forces
    /// SwiftUI to fully recreate the LazyVGrid, preventing hit-test/layout mismatches
    /// after rotation on iPad (GitHub issue #82 — wrong video tapped in landscape).
    @State private var orientationToken = UUID()
    #endif

    var body: some View {
        #if os(tvOS)
        let compact = false
        #else
        let compact = store.settings.compactThumbnails
        #endif
        if compact {
            LazyVStack(spacing: 0) {
                ForEach(videos) { video in
                    #if os(tvOS)
                    VideoCardView(video: video, compact: true, onSelect: { onSelect(video) })
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("video.card.\(video.id)")
                        .onAppear {
                            if video.id == videos.last?.id { loadMore?() }
                        }
                    #else

                    VideoCardView(video: video, compact: true)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("video.card.\(video.id)")
                        .accessibilityValue(video.isShort ? "short" : "")
                        .onTapGesture { onSelect(video) }
                        .onAppear {
                            if video.id == videos.last?.id { loadMore?() }
                        }
                    #endif
                    Divider().padding(.horizontal)
                }
            }
            #if os(tvOS)
            .focusSection()
            #endif
        } else {
            #if os(tvOS)
            // LazyVGrid on tvOS causes the first row of grid items to appear
            // invisible — the focus engine cannot traverse cells that have not
            // been laid out yet. Keep lazy rows, with an explicit 16:9 proposal
            // for each of the three cards.
            let columnCount = 3
            LazyVStack(alignment: .leading, spacing: videoGridRowSpacing) {
                ForEach(Array(stride(from: 0, to: videos.count, by: columnCount)), id: \.self) { startIdx in
                    let rowVideos = Array(videos[startIdx..<min(startIdx + columnCount, videos.count)])
                    TVVideoGridRowLayout(columnCount: columnCount, spacing: videoGridRowSpacing) {
                        ForEach(rowVideos) { video in
                            VideoCardView(video: video, compact: false, onSelect: { onSelect(video) })
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .accessibilityIdentifier("video.card.\(video.id)")
                                .id(video.id)
                                .focused($focusedVideoID, equals: video.id)
                        }
                        let remainder = columnCount - rowVideos.count
                        if remainder > 0 {
                            ForEach(0..<remainder, id: \.self) { _ in
                                Color.clear
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .onAppear {
                        if rowVideos.last?.id == videos.last?.id { loadMore?() }
                    }
                }
            }
            .padding(.horizontal, 0)
            .padding(.vertical, 8)
            #if os(tvOS)
            .focusSection()
            // Entering a three-column grid from Search used to preserve the
            // horizontal position of the filter control and land on card 3.
            // User-initiated entry must start at the leading result instead.
            .defaultFocus($focusedVideoID, videos.first?.id, priority: .userInitiated)
            .onChange(of: restoreFocusedVideoID, initial: true) { _, videoID in
                guard let videoID, videos.contains(where: { $0.id == videoID }) else { return }
                // Wait until the containing vertical ScrollView has brought the
                // target row back on-screen, then hand focus to the exact card.
                DispatchQueue.main.async {
                    focusedVideoID = videoID
                    onFocusRestored?(videoID)
                }
            }
            #endif
            #else
            let columns = horizontalSizeClass == .compact ? compactVideoGridColumns : regularVideoGridColumns
            LazyVGrid(columns: columns, spacing: videoGridRowSpacing) {
                ForEach(videos) { video in
                    VideoCardView(video: video, compact: false)
                        .accessibilityIdentifier("video.card.\(video.id)")
                        .accessibilityValue(video.isShort ? "short" : "")
                        .onTapGesture { onSelect(video) }
                        .onAppear {
                            if video.id == videos.last?.id { loadMore?() }
                        }
                }
            }
            .id(orientationToken)
            .padding(.horizontal)
            .padding(.vertical, 8)
            #if canImport(UIKit)
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                orientationToken = UUID()
            }
            #endif
            #endif
        }
    }
}

// MARK: - VideoRowSection

/// Horizontal scrolling shelf row — used for home feed shelves (layout == .row).
struct VideoRowSection: View {
    let videos: [Video]
    let onSelect: (Video) -> Void
    var cardWidth: CGFloat = 360
    var loadMore: (() -> Void)? = nil
    #if os(tvOS)
    var restoreFocusedVideoID: String? = nil
    var onFocusRestored: ((String) -> Void)? = nil
    #endif

    #if os(tvOS)
    @FocusState private var focusedVideoID: String?
    #endif

    @ViewBuilder
    private var horizontalScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Group {
            #if os(tvOS)
            // Lazy rendering is important for long TV shelves: an eager HStack
            // makes every off-screen card appear immediately, which fires every
            // continuation request at launch instead of when the viewer reaches
            // the right edge.
            LazyHStack(alignment: .top, spacing: videoGridRowSpacing) {
                ForEach(videos) { video in
                    VideoCardView(video: video, compact: false, onSelect: { onSelect(video) })
                        .frame(width: cardWidth)
                        .accessibilityIdentifier("video.card.\(video.id)")
                        .id(video.id)
                        .focused($focusedVideoID, equals: video.id)
                        .onAppear {
                            if video.id == videos.last?.id { loadMore?() }
                        }
                }
            }
            #else
            HStack(alignment: .top, spacing: videoGridRowSpacing) {
                ForEach(videos) { video in
                    VideoCardView(video: video, compact: false)
                        .frame(width: 220)
                        .accessibilityIdentifier("video.card.\(video.id)")
                        .onTapGesture { onSelect(video) }
                        .onAppear {
                            if video.id == videos.last?.id { loadMore?() }
                        }
                }
            }
            #endif
            }
            .padding(.leading, 32)
            .padding(.trailing, 64)
            .padding(.top, 22)
            .padding(.bottom, 26)
        }
    }

    var body: some View {
        #if os(tvOS)
        ScrollViewReader { proxy in
            horizontalScroll
                .scrollClipDisabled()
                .focusSection()
                // `.automatic` ignores the default during a user-initiated Siri Remote
                // move and preserves the X position from the previous shelf. Explicitly
                // prioritize the leading card whenever focus enters this row vertically.
                .defaultFocus($focusedVideoID, videos.first?.id, priority: .userInitiated)
                .onChange(of: restoreFocusedVideoID, initial: true) { _, videoID in
                    guard let videoID, videos.contains(where: { $0.id == videoID }) else { return }
                    // The parent restores the vertical shelf first. One run-loop
                    // later, restore this shelf's horizontal position and focus.
                    DispatchQueue.main.async {
                        proxy.scrollTo(videoID, anchor: .center)
                        focusedVideoID = videoID
                        onFocusRestored?(videoID)
                    }
                }
        }
        #else
        horizontalScroll
        #endif
    }
}
