import SwiftUI
import SmartTubeIOSCore

#if os(tvOS)
/// A focused account feed for the personal tvOS client.
/// It deliberately exposes one YouTube browse endpoint per top-level tab so the
/// Siri Remote never has to traverse a second row of section selectors.
struct PersonalTVFeedView: View {
    private let section: BrowseSection
    private let api: InnerTubeAPI

    @State private var viewModel: BrowseViewModel
    @State private var selectedVideo: Video?
    @State private var channelDestination: ChannelDestination?
    @State private var showSignIn = false
    @State private var playbackReturnVideoID: String?
    @State private var restoreFocusedVideoID: String?

    @Environment(AuthService.self) private var auth
    @Environment(SettingsStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    init(sectionType: BrowseSection.SectionType, api: InnerTubeAPI) {
        let section = BrowseSection(type: sectionType)
        self.section = section
        self.api = api
        _viewModel = State(initialValue: BrowseViewModel(api: api, initialSection: section))
    }

    var body: some View {
        Group {
            if !auth.isSignedIn {
                signedOutState
            } else if viewModel.isLoading && videos.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading \(section.title)")
            } else if let error = viewModel.error, videos.isEmpty {
                errorState(error)
            } else if videos.isEmpty {
                ContentUnavailableView(
                    "No \(section.title)",
                    systemImage: section.type == .history ? "clock" : "rectangle.stack",
                    description: Text("Pull to refresh or try again later.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VideoGridSection(
                            videos: videos,
                            onSelect: { video in
                                playbackReturnVideoID = video.id
                                restoreFocusedVideoID = nil
                                selectedVideo = video
                            },
                            loadMore: {
                                if let last = videos.last {
                                    viewModel.loadMoreIfNeeded(lastVideo: last)
                                }
                            },
                            restoreFocusedVideoID: restoreFocusedVideoID,
                            onFocusRestored: { videoID in
                                if restoreFocusedVideoID == videoID {
                                    restoreFocusedVideoID = nil
                                }
                            }
                        )
                        if viewModel.isLoading {
                            ProgressView().padding(32)
                        }
                    }
                    .onChange(of: selectedVideo?.id) { previousVideoID, currentVideoID in
                        guard previousVideoID != nil,
                              currentVideoID == nil,
                              let videoID = playbackReturnVideoID,
                              videos.contains(where: { $0.id == videoID })
                        else { return }

                        proxy.scrollTo(videoID, anchor: .center)
                        DispatchQueue.main.async {
                            restoreFocusedVideoID = videoID
                        }
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $selectedVideo) { video in
            PlayerView(video: video, api: api)
        }
        .navigationDestination(item: $channelDestination) { destination in
            ChannelView(channelId: destination.channelId)
        }
        .sheet(isPresented: $showSignIn) { SignInView() }
        .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
            guard let channelId = note.userInfo?["channelId"] as? String, !channelId.isEmpty else { return }
            channelDestination = ChannelDestination(channelId: channelId)
        }
        .task(id: auth.accessToken) {
            await viewModel.updateAuthToken(auth.accessToken)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { viewModel.refreshIfStale() }
        }
    }

    private var videos: [Video] {
        viewModel.videoGroups
            .flatMap(\.videos)
            .filter { !$0.isShort }
    }

    private var signedOutState: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            Text("Sign in to see your \(section.title.lowercased())")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Button("Sign in with Google") { showSignIn = true }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("feed.signInButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ error: Error) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Couldn’t load \(section.title)")
                .font(.title2.weight(.semibold))
            Text(error.localizedDescription)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { viewModel.reload(section: section) }
                .buttonStyle(.borderedProminent)
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
