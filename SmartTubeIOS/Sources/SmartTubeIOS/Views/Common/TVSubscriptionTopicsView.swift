#if os(tvOS)
import SwiftUI
import SmartTubeIOSCore

private enum TVSubscriptionTopicsLayout {
    // The enclosing tvOS TabView already applies the living-room safe area.
    // Adding another 80pt here caused the header and controls to drift right of
    // the video grid.
    static let horizontalInset: CGFloat = 0
    static let toolbarSpacing: CGFloat = 12
    static let topicButtonSpacing: CGFloat = 14
    static let controlHeight: CGFloat = 60
    static let refreshButtonWidth: CGFloat = 212
    static let pickerWidth: CGFloat = 1_080
    static let pickerMaximumHeight: CGFloat = 760
    static let pickerColumnSpacing: CGFloat = 16
    static let pickerRowSpacing: CGFloat = 14
    static let pickerCardHeight: CGFloat = 78
}

private enum TVSubscriptionControlFocus: Hashable {
    case refresh
    case topic(SubscriptionTopic)
    case allCategories
}

/// Full-width subscription feed with a compact Liquid Glass control layer.
/// Topic controls behave as tvOS tabs: moving focus activates the category.
struct TVSubscriptionTopicsView: View {
    private static let maximumInlineCategoryCount = 10

    let videos: [Video]
    let topicsModel: SubscriptionTopicsViewModel
    let isRefreshing: Bool
    let isLoadingMore: Bool
    let hasMoreContent: Bool
    let lastUpdatedAt: Date?
    let refreshErrorDescription: String?
    @Binding var selectedVideo: Video?
    @Binding var selectedTopicRawValue: String
    let onRefresh: () -> Void
    let onLoadMore: () -> Void

    @State private var showsCategoryPicker = false
    @State private var playbackReturnVideoID: String?
    @State private var restoreFocusedVideoID: String?
    @State private var presentedTopics: [SubscriptionTopic] = []
    @State private var categoryPickerTopics: [SubscriptionTopic] = []
    @FocusState private var focusedControl: TVSubscriptionControlFocus?

    private var selectedTopic: SubscriptionTopic {
        SubscriptionTopic(rawValue: selectedTopicRawValue) ?? .all
    }

    private var visibleVideos: [Video] {
        topicsModel.catalogVideos(in: selectedTopic, allVideos: videos)
    }

    private var populatedTopics: [SubscriptionTopic] {
        presentedTopics
    }

    private var quickTopics: [SubscriptionTopic] {
        // Existing controls are never removed when the catalogue grows. The
        // first ten remain stable and additional topics live in the picker.
        [.all] + Array(populatedTopics.prefix(Self.maximumInlineCategoryCount))
    }

    private var usesCategoryPicker: Bool {
        populatedTopics.count > Self.maximumInlineCategoryCount
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    controlLayer

                    if visibleVideos.isEmpty {
                        filteredEmptyState
                    } else {
                        videoGrid
                    }
                }
            }
            .onChange(of: selectedVideo?.id) { previousVideoID, currentVideoID in
                guard previousVideoID != nil,
                      currentVideoID == nil,
                      let videoID = playbackReturnVideoID,
                      visibleVideos.contains(where: { $0.id == videoID })
                else { return }

                proxy.scrollTo(videoID, anchor: .center)
                DispatchQueue.main.async {
                    restoreFocusedVideoID = videoID
                }
            }
            #if DEBUG
            .task {
                guard ProcessInfo.processInfo.arguments.contains("--subscription-preview-scroll-content") else {
                    return
                }
                try? await Task.sleep(for: .milliseconds(350))
                proxy.scrollTo("subscriptions.bottom", anchor: .bottom)
            }
            #endif
        }
        .sheet(isPresented: $showsCategoryPicker) {
            TVSubscriptionCategoryPicker(
                selectedTopicRawValue: $selectedTopicRawValue,
                topics: categoryPickerTopics
            )
        }
        .onChange(of: focusedControl) { _, control in
            guard case let .topic(topic) = control,
                  topic != selectedTopic
            else { return }
            // These controls are tabs, not commands. On tvOS the focused tab
            // immediately becomes active so browsing never requires an extra
            // Select/OK press.
            selectedTopicRawValue = topic.rawValue
        }
        // Rebuild categories only after the parent feed has completed a
        // successful initial load or Refresh. Pagination does not change
        // `lastUpdatedAt`, so scrolling never restarts or reorders the catalog.
        .task(id: lastUpdatedAt) {
            guard lastUpdatedAt != nil, !videos.isEmpty else { return }
            await topicsModel.refreshCatalog(from: videos)
            receiveAvailableTopics(topicsModel.availableCatalogTopics)
            if selectedTopic != .all,
               !topicsModel.availableCatalogTopics.contains(selectedTopic) {
                selectedTopicRawValue = SubscriptionTopic.all.rawValue
            }
        }
        .task(id: videos.map(\.id)) {
            // Pagination changes the video IDs without changing `lastUpdatedAt`.
            // Enrich only the timestamps; the tab topology remains untouched.
            await topicsModel.enrichPublishedDates(for: videos)
        }
        .onChange(of: topicsModel.availableCatalogTopics) { _, topics in
            receiveAvailableTopics(topics)
        }
        .onChange(of: showsCategoryPicker) { _, isPresented in
            if !isPresented {
                let available = Set(topicsModel.availableCatalogTopics)
                if selectedTopic != .all, !available.contains(selectedTopic) {
                    selectedTopicRawValue = SubscriptionTopic.all.rawValue
                }
            }
        }
        .onAppear {
            receiveAvailableTopics(topicsModel.availableCatalogTopics)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--subscription-preview-picker") {
                showsCategoryPicker = true
            }
            if ProcessInfo.processInfo.arguments.contains("--subscription-preview-focus-refresh") {
                DispatchQueue.main.async {
                    focusedControl = .refresh
                }
            }
            #endif
        }
    }

    private var controlLayer: some View {
        VStack(alignment: .leading, spacing: TVSubscriptionTopicsLayout.toolbarSpacing) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedTopic.localizedTitle)
                        .font(.system(size: 44, weight: .bold))
                        .tracking(-0.45)
                        .lineLimit(1)

                    statusLine
                }

                Spacer(minLength: 36)

                refreshButton
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TVSubscriptionTopicsLayout.topicButtonSpacing) {
                    ForEach(quickTopics, id: \.self) { topic in
                        quickTopicButton(topic)
                    }
                    if usesCategoryPicker {
                        categoriesButton
                    }
                }
                .padding(.vertical, 10)
            }
            .scrollClipDisabled()
            .focusSection()

            if refreshErrorDescription != nil, !videos.isEmpty {
                Label {
                    Text("Couldn’t refresh subscriptions. Your previous videos are still available.")
                } icon: {
                    Image(systemName: "wifi.exclamationmark")
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("subscriptions.refreshError")
            }
        }
        .padding(.horizontal, TVSubscriptionTopicsLayout.horizontalInset)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .zIndex(2)
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Text("\(visibleVideos.count) videos")
            if let lastUpdatedAt {
                Text("•")
                Text("Updated")
                Text(lastUpdatedAt, style: .relative)
            }
        }
        .font(.system(size: 21, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(height: 27, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var refreshButton: some View {
        Button {
            guard !isRefreshing else { return }
            // The parent fetches a fresh subscriptions snapshot. The catalog
            // refresh is triggered by the new `lastUpdatedAt`, never from this
            // pre-refresh (stale) array.
            onRefresh()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Image(systemName: "arrow.clockwise")
                        .opacity(isRefreshing ? 0 : 1)
                    ProgressView()
                        .controlSize(.small)
                        .tint(focusedControl == .refresh ? .black : .white)
                        .opacity(isRefreshing ? 1 : 0)
                }
                .frame(width: 22, height: 22)

                Text("Refresh")
                    .lineLimit(1)
            }
            .font(.system(size: 23, weight: .semibold))
        }
        .buttonStyle(
            SubscriptionControlButtonStyle(
                isSelected: false,
                fixedWidth: TVSubscriptionTopicsLayout.refreshButtonWidth
            )
        )
        .focused($focusedControl, equals: .refresh)
        .onMoveCommand { direction in
            guard direction == .down else { return }
            focusedControl = .topic(
                quickTopics.contains(selectedTopic) ? selectedTopic : .all
            )
        }
        .accessibilityIdentifier("subscriptions.refreshCategory")
        .accessibilityHint("Reloads subscriptions and keeps this topic selected")
        .accessibilityValue(isRefreshing ? "Refreshing" : "")
    }

    private func quickTopicButton(_ topic: SubscriptionTopic) -> some View {
        let isSelected = topic == selectedTopic
        return Button {
            selectedTopicRawValue = topic.rawValue
            focusedControl = .topic(topic)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: topic.symbolName)
                    .frame(width: 25)
                Text(topic.localizedTitle)
                    .lineLimit(1)
            }
            .font(.system(size: 23, weight: .semibold))
        }
        .buttonStyle(
            SubscriptionControlButtonStyle(
                isSelected: isSelected
            )
        )
        .focused($focusedControl, equals: .topic(topic))
        .onMoveCommand { direction in
            guard direction == .up else { return }
            focusedControl = .refresh
        }
        .accessibilityIdentifier("subscriptions.topic.\(topic.rawValue)")
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    private func receiveAvailableTopics(_ topics: [SubscriptionTopic]) {
        if topics.isEmpty {
            presentedTopics = []
            selectedTopicRawValue = SubscriptionTopic.all.rawValue
            return
        }

        let available = Set(topics)

        if selectedTopic != .all, !available.contains(selectedTopic) {
            let removedTopic = selectedTopic
            selectedTopicRawValue = SubscriptionTopic.all.rawValue
            if focusedControl == .topic(removedTopic) {
                focusedControl = .topic(.all)
            }
        }

        // Append-only control topology: actor responses can add focus targets,
        // but never remove or reorder buttons underneath the Siri Remote.
        for topic in topics where !presentedTopics.contains(topic) {
            presentedTopics.append(topic)
        }
    }

    private var additionalTopics: [SubscriptionTopic] {
        let inline = Set(quickTopics)
        return populatedTopics.filter { !inline.contains($0) }
    }

    private var categoriesButton: some View {
        Button {
            // The sheet receives an immutable snapshot, so a late archive
            // response cannot rearrange cards underneath remote focus.
            categoryPickerTopics = additionalTopics
            showsCategoryPicker = true
        } label: {
            Label("All Categories", systemImage: "square.grid.3x3")
                .font(.system(size: 23, weight: .semibold))
        }
        .buttonStyle(
            SubscriptionControlButtonStyle(
                isSelected: false
            )
        )
        .focused($focusedControl, equals: .allCategories)
        .onMoveCommand { direction in
            guard direction == .up else { return }
            focusedControl = .refresh
        }
        .accessibilityIdentifier("subscriptions.openCategories")
        .accessibilityHint("Shows additional subscription topics")
    }

    private var videoGrid: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 1)
                .id("subscriptions.top")

            VideoGridSection(
                videos: visibleVideos,
                onSelect: { video in
                    playbackReturnVideoID = video.id
                    restoreFocusedVideoID = nil
                    let capturedVideos = visibleVideos
                    Task { @MainActor in
                        await CurrentQueueStore.shared.replaceAll(with: capturedVideos)
                        let startIndex = capturedVideos.firstIndex(where: { $0.id == video.id }) ?? 0
                        selectedVideo = await CurrentQueueStore.shared.videoAt(index: startIndex) ?? video
                    }
                },
                loadMore: {
                    if selectedTopic == .all {
                        onLoadMore()
                    } else {
                        Task {
                            await topicsModel.loadMore(in: selectedTopic)
                        }
                    }
                },
                loadsMoreOnFocus: selectedTopic != .all,
                restoreFocusedVideoID: restoreFocusedVideoID,
                onFocusRestored: { videoID in
                    if restoreFocusedVideoID == videoID {
                        restoreFocusedVideoID = nil
                    }
                }
            )

            Color.clear
                .frame(height: 1)
                .id("subscriptions.bottom")
        }
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: selectedTopic.symbolName)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No videos in \(selectedTopic.localizedTitle)")
                .font(.system(size: 26, weight: .semibold))
            Text("Return to All Subscriptions.")
                .foregroundStyle(.secondary)

            Button("Show All") {
                selectedTopicRawValue = SubscriptionTopic.all.rawValue
            }
            .buttonStyle(SubscriptionControlButtonStyle(isSelected: false))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(80)
    }
}

// MARK: - Full category browser

private struct TVSubscriptionCategoryPicker: View {
    @Binding var selectedTopicRawValue: String
    let topics: [SubscriptionTopic]

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedTopic: SubscriptionTopic?

    private var selectedTopic: SubscriptionTopic {
        SubscriptionTopic(rawValue: selectedTopicRawValue) ?? .all
    }

    private var additionalTopics: [SubscriptionTopic] {
        topics
    }

    private var rowCount: Int {
        max(1, Int(ceil(Double(additionalTopics.count) / 2.0)))
    }

    private var contentHeight: CGFloat {
        let rowsHeight = CGFloat(rowCount) * TVSubscriptionTopicsLayout.pickerCardHeight
        let gapsHeight = CGFloat(max(0, rowCount - 1)) * TVSubscriptionTopicsLayout.pickerRowSpacing
        return min(
            TVSubscriptionTopicsLayout.pickerMaximumHeight,
            max(300, 154 + rowsHeight + gapsHeight)
        )
    }

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: TVSubscriptionTopicsLayout.pickerColumnSpacing),
        count: 2
    )

    var body: some View {
        pickerContent
    }

    private var pickerContent: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("More Categories")
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.3)
                Text("Additional topics from your subscriptions")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                LazyVGrid(
                    columns: columns,
                    spacing: TVSubscriptionTopicsLayout.pickerRowSpacing
                ) {
                    ForEach(additionalTopics, id: \.self) { topic in
                        topicCard(topic)
                    }
                }
                // Focused cards scale beyond their layout bounds. These insets
                // keep the first/last rows and their shadows away from the clip
                // boundary, including when defaultFocus scrolls to a later row.
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
            .scrollClipDisabled()
            .focusSection()
        }
        .frame(
            width: TVSubscriptionTopicsLayout.pickerWidth,
            height: contentHeight
        )
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .defaultFocus(
            $focusedTopic,
            additionalTopics.contains(selectedTopic) ? selectedTopic : additionalTopics.first,
            priority: .userInitiated
        )
        .onAppear {
            guard focusedTopic == nil else { return }
            DispatchQueue.main.async {
                focusedTopic = additionalTopics.contains(selectedTopic)
                    ? selectedTopic
                    : additionalTopics.first
            }
        }
        .onExitCommand { dismiss() }
    }

    private func topicCard(_ topic: SubscriptionTopic) -> some View {
        let isSelected = topic == selectedTopic
        return Button {
            selectedTopicRawValue = topic.rawValue
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: topic.symbolName)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 28)

                Text(topic.localizedTitle)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 8)

                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 20)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 18)
        }
        .buttonStyle(SubscriptionCategoryCardButtonStyle(isSelected: isSelected))
        .focused($focusedTopic, equals: topic)
        .zIndex(focusedTopic == topic ? 1 : 0)
        .accessibilityLabel(topic.localizedTitle)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint("Filters subscriptions by this topic")
        .accessibilityIdentifier("subscriptions.category.\(topic.rawValue)")
    }
}

// MARK: - Apple-native styling and localized presentation

private struct SubscriptionControlButtonStyle: ButtonStyle {
    let isSelected: Bool
    var fixedWidth: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        SubscriptionControlButtonStyleBody(
            configuration: configuration,
            isSelected: isSelected,
            fixedWidth: fixedWidth
        )
    }
}

private struct SubscriptionControlButtonStyleBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    let fixedWidth: CGFloat?

    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: Capsule { Capsule() }

    var body: some View {
        configuration.label
            .frame(width: fixedWidth)
            .frame(height: TVSubscriptionTopicsLayout.controlHeight)
            .padding(.horizontal, fixedWidth == nil ? 20 : 0)
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .background { background }
            .overlay {
                if isSelected, !isFocused {
                    shape.strokeBorder(Color.white.opacity(0.42), lineWidth: 1.4)
                }
            }
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.86 : 1)
    }

    @ViewBuilder
    private var background: some View {
        if reduceTransparency {
            shape.fill(isFocused ? Color.white : Color.black.opacity(isSelected ? 0.72 : 0.58))
        } else if #available(tvOS 26.0, *) {
            if isFocused {
                Color.clear.glassEffect(
                    .regular.tint(Color.white.opacity(0.82)).interactive(),
                    in: shape
                )
            } else {
                Color.clear.glassEffect(
                    .regular.tint(Color.white.opacity(isSelected ? 0.12 : 0.035)),
                    in: shape
                )
            }
        } else {
            shape.fill(isFocused ? Color.white : Color.white.opacity(isSelected ? 0.17 : 0.09))
        }
    }
}

private struct SubscriptionCategoryCardButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SubscriptionCategoryCardButtonStyleBody(
            configuration: configuration,
            isSelected: isSelected
        )
    }
}

private struct SubscriptionCategoryCardButtonStyleBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    var body: some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: TVSubscriptionTopicsLayout.pickerCardHeight)
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .background { background }
            .overlay {
                if isSelected, !isFocused {
                    shape.strokeBorder(Color.white.opacity(0.46), lineWidth: 1.5)
                }
            }
            .contentShape(shape)
            .shadow(
                color: isFocused ? Color.black.opacity(0.42) : .clear,
                radius: 16,
                y: 8
            )
            .opacity(configuration.isPressed ? 0.86 : 1)
    }

    @ViewBuilder
    private var background: some View {
        if reduceTransparency {
            shape.fill(isFocused ? Color.white : Color.black.opacity(isSelected ? 0.74 : 0.62))
        } else if #available(tvOS 26.0, *) {
            if isFocused {
                Color.clear.glassEffect(
                    .regular.tint(Color.white.opacity(0.84)).interactive(),
                    in: shape
                )
            } else {
                Color.clear.glassEffect(
                    .regular.tint(Color.white.opacity(isSelected ? 0.13 : 0.045)),
                    in: shape
                )
            }
        } else {
            shape.fill(isFocused ? Color.white : Color.white.opacity(isSelected ? 0.17 : 0.09))
        }
    }
}

private extension SubscriptionTopic {
    var localizedTitle: String {
        switch self {
        case .all: return String(localized: "subscription.topic.all", defaultValue: "All Subscriptions", bundle: .module)
        case .diyElectronics: return String(localized: "subscription.topic.diy_electronics", defaultValue: "DIY Electronics", bundle: .module)
        case .technology: return String(localized: "subscription.topic.technology", defaultValue: "Technology", bundle: .module)
        case .gaming: return String(localized: "subscription.topic.gaming", defaultValue: "Gaming", bundle: .module)
        case .newsPolitics: return String(localized: "subscription.topic.news_politics", defaultValue: "News & Politics", bundle: .module)
        case .science: return String(localized: "subscription.topic.science", defaultValue: "Science", bundle: .module)
        case .education: return String(localized: "subscription.topic.education", defaultValue: "Education", bundle: .module)
        case .businessFinance: return String(localized: "subscription.topic.business_finance", defaultValue: "Business & Finance", bundle: .module)
        case .autosVehicles: return String(localized: "subscription.topic.autos_vehicles", defaultValue: "Cars & Vehicles", bundle: .module)
        case .music: return String(localized: "subscription.topic.music", defaultValue: "Music", bundle: .module)
        case .filmAnimation: return String(localized: "subscription.topic.film_animation", defaultValue: "Film & Animation", bundle: .module)
        case .entertainment: return String(localized: "subscription.topic.entertainment", defaultValue: "Entertainment", bundle: .module)
        case .comedy: return String(localized: "subscription.topic.comedy", defaultValue: "Comedy", bundle: .module)
        case .travelEvents: return String(localized: "subscription.topic.travel_events", defaultValue: "Travel & Events", bundle: .module)
        case .foodLifestyle: return String(localized: "subscription.topic.food_lifestyle", defaultValue: "Food & Lifestyle", bundle: .module)
        case .sports: return String(localized: "subscription.topic.sports", defaultValue: "Sports", bundle: .module)
        case .petsAnimals: return String(localized: "subscription.topic.pets_animals", defaultValue: "Pets & Animals", bundle: .module)
        case .podcastsInterviews: return String(localized: "subscription.topic.podcasts_interviews", defaultValue: "Podcasts & Interviews", bundle: .module)
        case .peopleBlogs: return String(localized: "subscription.topic.people_blogs", defaultValue: "People & Blogs", bundle: .module)
        case .nonprofitsActivism: return String(localized: "subscription.topic.nonprofits_activism", defaultValue: "Nonprofits & Activism", bundle: .module)
        case .other: return String(localized: "subscription.topic.other", defaultValue: "Other", bundle: .module)
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "rectangle.stack"
        case .diyElectronics: return "memorychip"
        case .technology: return "cpu"
        case .gaming: return "gamecontroller"
        case .newsPolitics: return "newspaper"
        case .science: return "atom"
        case .education: return "graduationcap"
        case .businessFinance: return "chart.line.uptrend.xyaxis"
        case .autosVehicles: return "car"
        case .music: return "music.note"
        case .filmAnimation: return "film"
        case .entertainment: return "tv"
        case .comedy: return "theatermasks"
        case .travelEvents: return "airplane"
        case .foodLifestyle: return "fork.knife"
        case .sports: return "sportscourt"
        case .petsAnimals: return "pawprint"
        case .podcastsInterviews: return "mic"
        case .peopleBlogs: return "person.2"
        case .nonprofitsActivism: return "heart"
        case .other: return "ellipsis"
        }
    }

}

#if DEBUG
/// Network-free launch surface used only for tvOS Simulator design validation.
/// Launch with `--subscription-design-preview`; release builds contain no path
/// to this view.
struct TVSubscriptionTopicsVisualPreview: View {
    @State private var topicsModel: SubscriptionTopicsViewModel
    @State private var selectedVideo: Video?
    @State private var selectedTopicRawValue = SubscriptionTopic.all.rawValue
    @State private var isRefreshing = false
    @State private var isLoadingMore = false
    @State private var hasMoreContent = false
    @State private var paginationPage = 0
    @State private var previewVideos = Self.sampleVideos
    @State private var lastUpdatedAt = Date()

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let requestedTopic = arguments
            .first(where: { $0.hasPrefix("--subscription-preview-topic=") })
            .map { String($0.dropFirst("--subscription-preview-topic=".count)) }
        let initialTopic = requestedTopic.flatMap(SubscriptionTopic.init(rawValue:)) ?? .all

        let api = InnerTubeAPI()
        _selectedTopicRawValue = State(initialValue: initialTopic.rawValue)
        _isRefreshing = State(
            initialValue: arguments.contains("--subscription-preview-refreshing")
        )
        _hasMoreContent = State(
            initialValue: arguments.contains("--subscription-preview-pagination")
        )
        _topicsModel = State(
            initialValue: SubscriptionTopicsViewModel(
                api: api,
                metadataFetcher: { videoIDs in
                    Dictionary(uniqueKeysWithValues: videoIDs.map { videoID in
                        let categoryID: String
                        switch videoID {
                        case "electronics-1", "electronics-2": categoryID = "28"
                        case "gaming-1", "gaming-2": categoryID = "20"
                        case "news-1", "news-2": categoryID = "25"
                        case "science-1": categoryID = "28"
                        case "education-1": categoryID = "27"
                        case "business-1": categoryID = "22"
                        case "cars-1": categoryID = "2"
                        case "music-1": categoryID = "10"
                        default: categoryID = "24"
                        }
                        let tags = videoID == "science-1" ? ["physics", "science"] : []
                        return (
                            videoID,
                            VideoTopicMetadata(
                                videoID: videoID,
                                categoryID: categoryID,
                                tags: tags
                            )
                        )
                    })
                },
                channelVideosFetcher: { channelID, continuationToken in
                    Self.previewChannelPage(
                        channelID: channelID,
                        continuationToken: continuationToken
                    )
                },
                subscribedChannelsFetcher: {
                    []
                }
            )
        )
    }

    var body: some View {
        TVSubscriptionTopicsView(
            videos: previewVideos,
            topicsModel: topicsModel,
            isRefreshing: isRefreshing,
            isLoadingMore: isLoadingMore,
            hasMoreContent: hasMoreContent,
            lastUpdatedAt: lastUpdatedAt,
            refreshErrorDescription: nil,
            selectedVideo: $selectedVideo,
            selectedTopicRawValue: $selectedTopicRawValue,
            onRefresh: refresh,
            onLoadMore: loadMore
        )
        .padding(.horizontal, 80)
        .background(Color.black.ignoresSafeArea())
        .task {
            guard ProcessInfo.processInfo.arguments.contains("--subscription-model-self-test") else {
                return
            }
            let result = await SubscriptionTopicsDebugSelfTest.run()
            guard let documentsURL = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first else { return }
            try? result.write(
                to: documentsURL.appendingPathComponent("subscription-model-self-test.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            lastUpdatedAt = Date()
            isRefreshing = false
        }
    }

    private func loadMore() {
        guard hasMoreContent, !isLoadingMore else { return }
        isLoadingMore = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            paginationPage += 1
            previewVideos.append(contentsOf: Self.paginationVideos(page: paginationPage))
            hasMoreContent = paginationPage < 5
            isLoadingMore = false
        }
    }

    private static func paginationVideos(page: Int) -> [Video] {
        (1...24).map { index in
            let absoluteIndex = ((page - 1) * 24) + index
            return Video(
                id: "diy-page-\(absoluteIndex)",
                title: "DIY electronics project \(absoluteIndex)",
                channelTitle: "Workshop Lab"
            )
        }
    }

    nonisolated private static func previewChannelPage(
        channelID: String,
        continuationToken: String?
    ) -> VideoGroup {
        let page = Int(continuationToken ?? "0") ?? 0
        let channelTitle: String
        let subject: String
        switch channelID {
        case "preview-workshop": (channelTitle, subject) = ("Workshop Lab", "DIY electronics")
        case "preview-diy-bench": (channelTitle, subject) = ("DIY Bench", "Custom electronics")
        case "preview-gaming": (channelTitle, subject) = ("Game Room", "Gaming")
        case "preview-news": (channelTitle, subject) = ("Daily Report", "News")
        case "preview-science": (channelTitle, subject) = ("Science Lab", "Science")
        case "preview-education": (channelTitle, subject) = ("Computer Course", "Education")
        case "preview-business": (channelTitle, subject) = ("Business Desk", "Business")
        case "preview-cars": (channelTitle, subject) = ("Road Review", "Cars")
        case "preview-music": (channelTitle, subject) = ("Sound Room", "Music")
        default: (channelTitle, subject) = ("Studio", "Entertainment")
        }
        let videos = (1...30).map { index in
            let absoluteIndex = page * 30 + index
            return Video(
                id: "\(channelID)-archive-\(absoluteIndex)",
                title: "\(subject) video \(absoluteIndex)",
                channelTitle: channelTitle,
                channelId: channelID,
                publishedAt: Date().addingTimeInterval(TimeInterval(-absoluteIndex * 86_400))
            )
        }
        return VideoGroup(
            videos: videos,
            nextPageToken: page < 7 ? String(page + 1) : nil
        )
    }

    private static let sampleVideos: [Video] = [
        previewVideo(id: "electronics-1", title: "Build an ESP32 smart display", channel: "Workshop Lab", channelID: "preview-workshop", minutesAgo: 8, views: 123_000),
        previewVideo(id: "gaming-1", title: "The best games this week", channel: "Game Room", channelID: "preview-gaming", minutesAgo: 42, views: 84_000),
        previewVideo(id: "news-1", title: "World news briefing", channel: "Daily Report", channelID: "preview-news", minutesAgo: 125, views: 46_000),
        previewVideo(id: "science-1", title: "A new quantum discovery", channel: "Science Lab", channelID: "preview-science", minutesAgo: 310, views: 19_000),
        previewVideo(id: "education-1", title: "How compilers work", channel: "Computer Course", channelID: "preview-education", minutesAgo: 540, views: 11_000),
        previewVideo(id: "business-1", title: "Markets and startups", channel: "Business Desk", channelID: "preview-business", minutesAgo: 900, views: 7_800),
        previewVideo(id: "cars-1", title: "Electric car road test", channel: "Road Review", channelID: "preview-cars", minutesAgo: 1_320, views: 215_000),
        previewVideo(id: "music-1", title: "Studio session", channel: "Sound Room", channelID: "preview-music", minutesAgo: 1_500, views: 92_000),
        previewVideo(id: "electronics-2", title: "Soldering a custom keyboard", channel: "DIY Bench", channelID: "preview-diy-bench", minutesAgo: 2_880, views: 33_000),
        previewVideo(id: "gaming-2", title: "Console hardware explained", channel: "Game Room", channelID: "preview-gaming", minutesAgo: 4_320, views: 140_000),
        previewVideo(id: "news-2", title: "Politics weekly", channel: "Daily Report", channelID: "preview-news", minutesAgo: 5_760, views: 61_000),
        previewVideo(id: "entertainment-1", title: "Behind the scenes", channel: "Studio", channelID: "preview-studio", minutesAgo: 7_200, views: 27_000),
    ]

    nonisolated private static func previewVideo(
        id: String,
        title: String,
        channel: String,
        channelID: String,
        minutesAgo: Int,
        views: Int
    ) -> Video {
        let exactDate = Date().addingTimeInterval(-TimeInterval(minutesAgo * 60))
        return Video(
            id: id,
            title: title,
            channelTitle: channel,
            channelId: channelID,
            viewCount: views,
            publishedAt: exactDate,
            exactPublishedAt: exactDate,
            publishedTimeText: minutesAgo < 24 * 60 ? "Today" : nil
        )
    }
}

private actor SubscriptionTopicsDebugMetadataGate {
    private var didStart = false
    private var continuation: CheckedContinuation<[String: VideoTopicMetadata], Never>?

    func fetch(videoIDs _: [String]) async -> [String: VideoTopicMetadata] {
        didStart = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        while !didStart {
            await Task.yield()
        }
    }

    func finish(with metadata: [String: VideoTopicMetadata]) {
        continuation?.resume(returning: metadata)
        continuation = nil
    }
}

private actor SubscriptionTopicsDebugChannelGate {
    private var didStart = false
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func fetch(channelID: String, continuationToken: String?) async -> VideoGroup {
        if !isOpen {
            didStart = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        guard channelID == "self-test-gaming-channel" else {
            return VideoGroup()
        }
        let page = Int(continuationToken ?? "0") ?? 0
        return VideoGroup(
            videos: (1...30).map { index in
                Video(
                    id: "self-test-archive-\(page)-\(index)",
                    title: "Game archive \(page)-\(index)",
                    channelTitle: "Game Room",
                    channelId: channelID
                )
            },
            nextPageToken: page < 7 ? String(page + 1) : nil
        )
    }

    func waitUntilStarted() async {
        while !didStart {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private enum SubscriptionTopicsDebugSelfTest {
    static func run() async -> String {
        let formatterReferenceDate = Date()
        let exactRecentDate = formatterReferenceDate.addingTimeInterval(-2 * 3_600)
        let exactRecentVideo = Video(
            id: "self-test-exact-date",
            title: "Exact date",
            channelTitle: "Channel",
            publishedAt: formatterReferenceDate,
            exactPublishedAt: exactRecentDate,
            publishedTimeText: "Today"
        )
        guard let exactLabel = VideoPublishAgeFormatter.label(
            for: exactRecentVideo,
            relativeTo: formatterReferenceDate
        ),
              exactLabel.caseInsensitiveCompare("Today") != .orderedSame
        else {
            return "FAIL: exact timestamp did not replace Today"
        }

        let cache = SubscriptionTopicMetadataCache(
            debugSuiteName: "SubscriptionTopicsDebugSelfTest.\(UUID().uuidString)"
        )
        await cache.clear()

        let datedOldVideo = Video(
            id: "self-test-two-weeks-old",
            title: "Old upload",
            channelTitle: "Old Channel",
            publishedAt: formatterReferenceDate.addingTimeInterval(-14 * 86_400)
        )
        let freshInitiallyUndatedVideo = Video(
            id: "self-test-fresh-undated",
            title: "Fresh upload",
            channelTitle: "Fresh Channel"
        )
        let freshnessModel = SubscriptionTopicsViewModel(
            api: InnerTubeAPI(),
            cache: cache,
            metadataFetcher: { _ in
                [
                    datedOldVideo.id: VideoTopicMetadata(
                        videoID: datedOldVideo.id,
                        categoryID: "20",
                        tags: [],
                        publishedAt: formatterReferenceDate.addingTimeInterval(-14 * 86_400)
                    ),
                    freshInitiallyUndatedVideo.id: VideoTopicMetadata(
                        videoID: freshInitiallyUndatedVideo.id,
                        categoryID: "20",
                        tags: [],
                        publishedAt: formatterReferenceDate.addingTimeInterval(-12 * 60)
                    ),
                ]
            }
        )
        await freshnessModel.prepareCatalog(
            from: [datedOldVideo, freshInitiallyUndatedVideo]
        )
        let expectedFreshnessOrder = [
            freshInitiallyUndatedVideo.id,
            datedOldVideo.id,
        ]
        guard freshnessModel.catalogVideos(
            in: .all,
            allVideos: [datedOldVideo, freshInitiallyUndatedVideo]
        ).map(\.id) == expectedFreshnessOrder else {
            return "FAIL: All Subscriptions did not sort by exact newest date"
        }
        guard freshnessModel.catalogVideos(
            in: .gaming,
            allVideos: []
        ).map(\.id) == expectedFreshnessOrder else {
            return "FAIL: a topic feed did not sort by exact newest date"
        }

        let previousVideo = Video(
            id: "self-test-gaming",
            title: "Weekly roundup",
            channelTitle: "Channel"
        )
        await cache.store([
            previousVideo.id: VideoTopicMetadata(
                videoID: previousVideo.id,
                categoryID: "20",
                tags: []
            )
        ])

        let gate = SubscriptionTopicsDebugMetadataGate()
        let model = SubscriptionTopicsViewModel(
            api: InnerTubeAPI(),
            cache: cache,
            metadataFetcher: { videoIDs in
                await gate.fetch(videoIDs: videoIDs)
            }
        )
        await model.enrich(videos: [previousVideo])

        guard model.videos(in: .gaming, from: [previousVideo]).map(\.id) == [previousVideo.id] else {
            return "FAIL: initial classified snapshot is incorrect"
        }

        let replacementVideo = Video(
            id: "self-test-science",
            title: "A new discovery",
            channelTitle: "Lab"
        )
        let replacementTask = Task {
            await model.enrich(videos: [replacementVideo])
        }
        await gate.waitUntilStarted()

        guard model.isLoading,
              model.classifiedVideos.map(\.id) == [previousVideo.id],
              model.videos(in: .gaming, from: [replacementVideo]).map(\.id) == [previousVideo.id]
        else {
            return "FAIL: visible snapshot changed before metadata completed"
        }

        await gate.finish(with: [
            replacementVideo.id: VideoTopicMetadata(
                videoID: replacementVideo.id,
                categoryID: "28",
                tags: ["physics"]
            )
        ])
        await replacementTask.value

        guard !model.isLoading,
              model.classifiedVideos.map(\.id) == [replacementVideo.id],
              model.videos(in: .gaming, from: [replacementVideo]).isEmpty,
              model.videos(in: .science, from: [replacementVideo]).map(\.id) == [replacementVideo.id]
        else {
            return "FAIL: replacement snapshot was not published atomically"
        }

        // Covers the exact one-tab regression observed on Apple TV. Useful
        // categories must be derived from the already visible subscriptions
        // page, without waiting for any channel archive request.
        let realisticSeeds = [
            Video(id: "seed-bitcoin", title: "Bitcoin market review", channelTitle: "Market Desk", channelId: "seed-business"),
            Video(id: "seed-unicycle", title: "Electric unicycle road test", channelTitle: "Wrong Way", channelId: "seed-autos"),
            Video(id: "seed-headphones", title: "New wireless headphones", channelTitle: "Tech Review", channelId: "seed-technology"),
            Video(id: "seed-news", title: "World news and politics", channelTitle: "News Desk", channelId: "seed-news-channel"),
            Video(id: "seed-stalker", title: "STALKER 2 gameplay", channelTitle: "Game Room", channelId: "seed-gaming"),
            Video(id: "seed-doctor", title: "Doctor explains nutrition", channelTitle: "Health Lab", channelId: "seed-health"),
        ]
        let immediateTopicsModel = SubscriptionTopicsViewModel(
            api: InnerTubeAPI(),
            cache: cache,
            metadataFetcher: { _ in [:] },
            channelVideosFetcher: { _, _ in VideoGroup() },
            subscribedChannelsFetcher: { [] }
        )
        await immediateTopicsModel.prepareCatalog(from: realisticSeeds)
        let expectedImmediateTopics: Set<SubscriptionTopic> = [
            .businessFinance, .autosVehicles, .technology,
            .newsPolitics, .gaming, .foodLifestyle,
        ]
        let actualImmediateTopics = Set(
            immediateTopicsModel.catalogCounts.compactMap { topic, count in
                count > 0 ? topic : nil
            }
        )
        guard expectedImmediateTopics.isSubset(of: actualImmediateTopics) else {
            return "FAIL: realistic first page produced only All Subscriptions"
        }

        let archiveSeed = Video(
            id: "self-test-archive-seed",
            title: "Gaming weekly",
            channelTitle: "Game Room",
            channelId: "self-test-gaming-channel"
        )
        let otherSeed = Video(
            id: "self-test-other-seed",
            title: "A regular upload",
            channelTitle: "Personal Channel",
            channelId: "self-test-other-channel"
        )
        let channelGate = SubscriptionTopicsDebugChannelGate()
        let catalogModel = SubscriptionTopicsViewModel(
            api: InnerTubeAPI(),
            cache: cache,
            metadataFetcher: { videoIDs in
                Dictionary(uniqueKeysWithValues: videoIDs.map { videoID in
                    (
                        videoID,
                        VideoTopicMetadata(
                            videoID: videoID,
                            categoryID: videoID == archiveSeed.id ? "20" : nil,
                            tags: []
                        )
                    )
                })
            },
            channelVideosFetcher: { channelID, continuationToken in
                await channelGate.fetch(
                    channelID: channelID,
                    continuationToken: continuationToken
                )
            },
            subscribedChannelsFetcher: {
                []
            }
        )
        let catalogTask = Task {
            await catalogModel.prepareCatalog(from: [archiveSeed, otherSeed])
        }
        await channelGate.waitUntilStarted()
        guard catalogModel.catalogCounts[.gaming] == 1,
              catalogModel.catalogCounts[.other] == nil
        else {
            return "FAIL: first-page topic was hidden while archive prefetch waited"
        }
        await channelGate.open()
        await catalogTask.value
        guard catalogModel.catalogCounts[.gaming] == 121,
              catalogModel.catalogCounts[.other] == nil
        else {
            return "FAIL: background archive did not reach 121 videos or included Other"
        }
        await catalogModel.loadMore(in: .gaming)
        guard catalogModel.catalogCounts[.gaming] == 151 else {
            return "FAIL: scroll loading did not append the next archive batch"
        }

        await cache.clear()
        return "PASS: exact newest-first All and topic feeds; six tabs visible immediately; stable snapshot; 121-video archive; Other hidden; automatic scroll loading appended to 151"
    }
}
#endif
#endif
