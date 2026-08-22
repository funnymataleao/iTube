import SwiftUI
import SmartTubeIOSCore

private struct ChannelSubscriptionContext: Hashable {
    let channelID: String?
    let accessToken: String?
}

#if os(tvOS)
private enum TVChannelHeaderAction: Hashable {
    case subscription
    case sponsorBlock
}
#endif

// MARK: - ChannelView
//
// Displays channel info, subscriber count and a grid of recent uploads.
// Mirrors the Android `ChannelFragment`.

public struct ChannelView: View {
    public let channelId: String
    @State private var vm = ChannelViewModel()
    @State private var selectedVideo: Video?
    @State private var channelDestination: ChannelDestination?
    @State private var isFollowedLocally = false
    @State private var isSubscribed = false
    @State private var hasResolvedSubscriptionState = false
    @State private var isUpdatingSubscription = false
    @State private var subscriptionRevision = 0
    @State private var subscriptionError: String?
    #if os(tvOS)
    @FocusState private var focusedHeaderAction: TVChannelHeaderAction?
    #endif
    @Environment(SettingsStore.self) private var store
    @Environment(AuthService.self) private var auth
    @Environment(\.innerTubeAPI) private var api
    #if os(iOS)
    @Environment(PlayerRouter.self) private var playerRouter
    #endif

    public init(channelId: String) {
        self.channelId = channelId
    }

    public var body: some View {
        Group {
            if vm.isLoading && vm.channel == nil {
                ProgressView("Loading channel…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("channel.view")
            } else {
                content
            }
        }
        #if os(tvOS)
        // The channel belongs to the app's main NavigationStack. Keep the page
        // opaque while preserving the native top TabView navigation on tvOS.
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.visible, for: .tabBar)
        #else
        .navigationTitle(vm.channel?.title ?? "Channel")
        #endif
        .onAppear { vm.load(channelId: channelId, api: api) }
        .task(id: subscriptionContext) {
            guard let channel = vm.channel else { return }
            await refreshSubscriptionState(for: channel)
        }
        #if !os(iOS) && !os(macOS)
        .fullScreenCover(item: $selectedVideo) { video in
            PlayerView(video: video, api: api)
        }
        #endif
        #if os(macOS)
        .navigationDestination(item: $selectedVideo) { video in
            PlayerView(video: video, api: api)
        }
        #endif
        .navigationDestination(item: $channelDestination) { dest in
            ChannelView(channelId: dest.channelId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
            guard let channelId = note.userInfo?["channelId"] as? String, !channelId.isEmpty else { return }
            if channelId == self.channelId {
                return
            }
            channelDestination = ChannelDestination(channelId: channelId)
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { vm.error != nil },
                set: { if !$0 { vm.error = nil } }
            ),
            presenting: vm.error
        ) { _ in
            Button("Retry") {
                vm.error = nil
                vm.load(channelId: channelId, api: api)
            }
            Button("Dismiss", role: .cancel) { vm.error = nil }
        } message: { err in
            Text(err.localizedDescription)
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { subscriptionError != nil },
                set: { if !$0 { subscriptionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { subscriptionError = nil }
        } message: {
            Text(subscriptionError ?? "")
        }
        .toolbar {
            #if !os(tvOS)
            if let channel = vm.channel, auth.accessToken?.isEmpty == false {
                #if os(macOS)
                ToolbarItem(placement: .automatic) {
                    let isExcluded = store.settings.sponsorBlockExcludedChannels[channel.id] != nil
                    Button {
                        toggleSponsorBlockExclusion(for: channel)
                    } label: {
                        Label(
                            isExcluded ? "Enable SponsorBlock" : "Disable SponsorBlock",
                            systemImage: isExcluded ? "checkmark.shield" : "shield.slash"
                        )
                    }
                }
                #else
                ToolbarItem(placement: .topBarTrailing) {
                    let isExcluded = store.settings.sponsorBlockExcludedChannels[channel.id] != nil
                    Button {
                        toggleSponsorBlockExclusion(for: channel)
                    } label: {
                        Label(
                            isExcluded ? "Enable SponsorBlock" : "Disable SponsorBlock",
                            systemImage: isExcluded ? "checkmark.shield" : "shield.slash"
                        )
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .accessibilityIdentifier("channel.sponsorBlockButton")
                }
                #endif
            }
            #endif
        }
    }

    private var subscriptionContext: ChannelSubscriptionContext {
        ChannelSubscriptionContext(
            channelID: vm.channel?.id,
            accessToken: auth.accessToken
        )
    }

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        tvChannelPage
        #else
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let channel = vm.channel {
                    channelHeader(channel)
                }

                videosGrid(filteredVideos)

                if vm.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
        .refreshable { vm.load(channelId: channelId) }
        .accessibilityIdentifier("channel.view")
        #endif
    }

    #if os(tvOS)
    /// One opaque tvOS scroll surface. The channel identity/actions are ordinary
    /// content at the top and naturally leave the viewport as the user moves down.
    private var tvChannelPage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let channel = vm.channel {
                    tvChannelHeader(channel)

                    Divider()
                        .overlay(Color.white.opacity(0.12))
                        .padding(.horizontal, 80)
                }

                Group {
                    if filteredVideos.isEmpty && !vm.isLoading {
                        ContentUnavailableView(
                            "Nothing here yet",
                            systemImage: "play.rectangle"
                        )
                        .frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        videosGrid(filteredVideos)
                    }

                    if vm.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.top, 30)
                .padding(.bottom, 72)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .accessibilityIdentifier("channel.view")
        .task(id: vm.channel?.id) {
            guard vm.channel != nil else { return }
            // A NavigationStack push keeps focus on the originating tab item.
            // Move focus to the primary channel action once the async header is
            // actually in the hierarchy; Up then returns directly to the tab bar.
            await Task.yield()
            focusedHeaderAction = .subscription
        }
    }

    private func tvChannelHeader(_ channel: Channel) -> some View {
        HStack(spacing: 24) {
            channelAvatar(channel)

            VStack(alignment: .leading, spacing: 9) {
                Text(channel.title.isEmpty ? "Channel" : channel.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .accessibilityIdentifier("channel.title")

                HStack(spacing: 18) {
                    if let subscribers = channel.subscriberCount, !subscribers.isEmpty {
                        Label(subscribers, systemImage: "person.2.fill")
                    }

                    Label(videoCountLabel, systemImage: "play.rectangle.fill")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

                if let description = channel.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 680, alignment: .leading)
                }

                HStack(spacing: 14) {
                    subscriptionButton(channel)
                        .focused($focusedHeaderAction, equals: .subscription)

                    if auth.accessToken?.isEmpty == false {
                        sponsorBlockButton(channel)
                            .focused($focusedHeaderAction, equals: .sponsorBlock)
                    }
                }
                .focusSection()
                .defaultFocus(
                    $focusedHeaderAction,
                    .subscription,
                    priority: .userInitiated
                )
                .padding(.top, 3)
            }

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 80)
        .padding(.top, 28)
        .padding(.bottom, 22)
        .background(Color.black)
        .accessibilityIdentifier("channel.header")
    }

    private func channelAvatar(_ channel: Channel) -> some View {
        Group {
            if let url = channel.thumbnailURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        channelAvatarPlaceholder(channel)
                    }
                }
            } else {
                channelAvatarPlaceholder(channel)
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.24), lineWidth: 2))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        .accessibilityHidden(true)
    }

    private func channelAvatarPlaceholder(_ channel: Channel) -> some View {
        Circle()
            .fill(Color.secondary.opacity(0.24))
            .overlay {
                Text(channel.title.first.map { String($0).uppercased() } ?? "•")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(.secondary)
            }
    }

    private func subscriptionButton(_ channel: Channel) -> some View {
        let active = auth.isSignedIn ? isSubscribed : isFollowedLocally
        let isResolving = auth.isSignedIn && !hasResolvedSubscriptionState
        let title: String
        if isResolving {
            title = String(localized: "Checking…", bundle: .module)
        } else if auth.isSignedIn {
            title = active
                ? String(localized: "Unsubscribe", bundle: .module)
                : String(localized: "Subscribe", bundle: .module)
        } else {
            title = active
                ? String(localized: "Unfollow", bundle: .module)
                : String(localized: "Follow", bundle: .module)
        }

        return Button {
            if auth.isSignedIn {
                toggleSubscription(for: channel)
            } else {
                Task { await toggleFollow(channel) }
            }
        } label: {
            HStack(spacing: 10) {
                if isUpdatingSubscription || isResolving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: active ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus")
                }
                Text(title)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(isUpdatingSubscription || isResolving)
        .accessibilityIdentifier("channel.subscriptionButton")
        .accessibilityValue(isResolving ? "Loading" : (active ? "On" : "Off"))
    }

    private func sponsorBlockButton(_ channel: Channel) -> some View {
        let isExcluded = store.settings.sponsorBlockExcludedChannels[channel.id] != nil
        return Button {
            toggleSponsorBlockExclusion(for: channel)
        } label: {
            Label(
                isExcluded ? "Enable SponsorBlock" : "Disable SponsorBlock",
                systemImage: isExcluded ? "checkmark.shield" : "shield.slash"
            )
            .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .accessibilityIdentifier("channel.sponsorBlockButton")
    }

    private var videoCountLabel: String {
        let count = filteredVideos.count
        return String(
            localized: "\(count) video\(count == 1 ? "" : "s")",
            bundle: .module
        )
    }
    #endif

    // MARK: - Filtered data

    private var filteredVideos: [Video] {
        vm.videos.filter { !$0.isShort }
    }

    // MARK: - Grid layouts

    private func videosGrid(_ videos: [Video]) -> some View {
        VideoGridSection(
            videos: videos,
            onSelect: { video in
                #if os(iOS)
                playerRouter.open(video: video, api: api)
                #elseif os(tvOS)
                let capturedVideos = videos
                Task { @MainActor in
                    await CurrentQueueStore.shared.replaceAll(with: capturedVideos)
                    let startIndex = capturedVideos.firstIndex(where: { $0.id == video.id }) ?? 0
                    selectedVideo = await CurrentQueueStore.shared.videoAt(index: startIndex) ?? video
                }
                #else
                selectedVideo = video
                #endif
            },
            loadMore: vm.loadMore,
            showsChannelAvatar: false,
            prefersLeadingDefaultFocus: false
        )
    }

    private func toggleSponsorBlockExclusion(for channel: Channel) {
        if store.settings.sponsorBlockExcludedChannels[channel.id] != nil {
            store.settings.sponsorBlockExcludedChannels.removeValue(forKey: channel.id)
        } else {
            store.settings.sponsorBlockExcludedChannels[channel.id] = channel.title
        }
    }

    @MainActor
    private func refreshSubscriptionState(for channel: Channel) async {
        let revision = subscriptionRevision
        let localState = await isFollowingLocally(channel)
        guard !Task.isCancelled, revision == subscriptionRevision else { return }

        isFollowedLocally = localState
        // A guest's local follows must not leak into a signed-in account. Until
        // YouTube resolves the account-specific state, use only the renderer's
        // signed-in hint; the local value remains available for guest mode.
        isSubscribed = auth.isSignedIn ? channel.isSubscribed : localState
        if isSubscribed {
            hasResolvedSubscriptionState = true
        }

        guard let token = auth.accessToken, !token.isEmpty else {
            hasResolvedSubscriptionState = true
            return
        }
        do {
            await api.setAuthToken(token)
            let remoteState = try await api.isSubscribed(to: channel.id)
            guard !Task.isCancelled, revision == subscriptionRevision else { return }

            // A successful remote lookup is authoritative. OR-ing it with an
            // old local value makes a server-side unsubscribe appear stuck.
            isSubscribed = remoteState
            isFollowedLocally = remoteState
            hasResolvedSubscriptionState = true
            if remoteState && !localState {
                await LocalSubscriptionStore.shared.follow(
                    LocalChannel(
                        id: channel.id,
                        title: channel.title,
                        thumbnailURL: channel.thumbnailURL
                    )
                )
            } else if !remoteState && localState {
                await unfollowLocalAliases(for: channel)
            }
        } catch {
            // The local state is a useful offline fallback. A failed initial check
            // must not turn page entry into an error modal; explicit mutations do.
            hasResolvedSubscriptionState = true
        }
    }

    @MainActor
    private func toggleSubscription(for channel: Channel) {
        guard !isUpdatingSubscription else { return }
        guard let token = auth.accessToken, !token.isEmpty else {
            subscriptionError = String(localized: "Sign in to subscribe.", bundle: .module)
            return
        }

        subscriptionRevision &+= 1
        let revision = subscriptionRevision
        let previousState = isSubscribed
        let requestedState = !previousState
        isSubscribed = requestedState
        hasResolvedSubscriptionState = true
        isUpdatingSubscription = true

        Task { @MainActor in
            do {
                await api.setAuthToken(token)
                if requestedState {
                    try await api.subscribe(channelId: channel.id)
                    await LocalSubscriptionStore.shared.follow(
                        LocalChannel(
                            id: channel.id,
                            title: channel.title,
                            thumbnailURL: channel.thumbnailURL
                        )
                    )
                } else {
                    try await api.unsubscribe(channelId: channel.id)
                    await unfollowLocalAliases(for: channel)
                }

                guard subscriptionRevision == revision else { return }
                isSubscribed = requestedState
                isFollowedLocally = requestedState
            } catch {
                guard subscriptionRevision == revision else { return }
                isSubscribed = previousState
                subscriptionError = String(
                    localized: "Couldn't update the subscription. Try again.",
                    bundle: .module
                )
            }

            if subscriptionRevision == revision {
                isUpdatingSubscription = false
            }
        }
    }

    private func channelHeader(_ channel: Channel) -> some View {
        HStack(spacing: 16) {
            AsyncImage(url: channel.thumbnailURL) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Color.secondary.opacity(0.3))
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(channel.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("channel.title")
                if let subs = channel.subscriberCount {
                    Text(subs)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let desc = channel.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if !auth.isSignedIn {
                Button {
                    Task { await toggleFollow(channel) }
                } label: {
                    Label(
                        isFollowedLocally ? "Unfollow" : "Follow",
                        systemImage: isFollowedLocally ? "bell.slash" : "bell"
                    )
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("channel.followButton")
            }
        }
        .padding()
        .background(.background)
        .accessibilityIdentifier("channel.header")
    }

    private func toggleFollow(_ channel: Channel) async {
        if isFollowedLocally {
            await unfollowLocalAliases(for: channel)
            isFollowedLocally = false
        } else {
            let local = LocalChannel(
                id: channel.id,
                title: channel.title,
                thumbnailURL: channel.thumbnailURL
            )
            await LocalSubscriptionStore.shared.follow(local)
            isFollowedLocally = true
        }
    }

    private func isFollowingLocally(_ channel: Channel) async -> Bool {
        for id in localSubscriptionAliases(for: channel) {
            if await LocalSubscriptionStore.shared.isFollowing(id) {
                return true
            }
        }
        return false
    }

    private func unfollowLocalAliases(for channel: Channel) async {
        for id in localSubscriptionAliases(for: channel) {
            await LocalSubscriptionStore.shared.unfollow(channelId: id)
        }
    }

    private func localSubscriptionAliases(for channel: Channel) -> [String] {
        var seen = Set<String>()
        return [channel.id, channelId]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
