import SwiftUI
import SmartTubeIOSCore

// MARK: - SearchView
//
// Search interface with live suggestions and paginated results.
// Mirrors the Android `SearchTagsActivity`.

public struct SearchView: View {
    @Environment(SearchViewModel.self) private var vm
    @Environment(\.innerTubeAPI) private var api
    @Environment(SettingsStore.self) private var store
    @State private var selectedVideo: Video?
    @State private var channelDestination: ChannelDestination?
    @State private var showFilterSheet = false
    @State private var showClearHistoryConfirmation = false
    @FocusState private var isSearchFocused: Bool
    #if os(iOS)
    @Environment(PlayerRouter.self) private var playerRouter
    #endif

    public init() {}

    public var body: some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            #if !os(tvOS)
            searchBar
            Divider()
            #endif
            if !vm.query.isEmpty {
                filterChipsRow
            }
            Group {
                #if os(tvOS)
                if vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    tvOSHistoryView
                } else if vm.displayedQuery != vm.query.trimmingCharacters(in: .whitespacesAndNewlines) {
                    searchPendingView
                } else if vm.isLoading || !vm.results.isEmpty {
                    resultsView
                } else if vm.error != nil {
                    searchErrorView
                } else {
                    noResultsView
                }
                #else
                if isSearchFocused {
                    suggestionsListView
                } else if vm.isLoading || !vm.results.isEmpty {
                    resultsView
                } else if !vm.query.isEmpty {
                    noResultsView
                } else {
                    suggestionsListView
                }
                #endif
            }
        }
        #if os(tvOS)
        .searchable(text: $vm.query, prompt: "Search YouTube")
        .onSubmit(of: .search) {
            vm.search()
        }
        .fullScreenCover(item: $selectedVideo) { video in
            PlayerView(video: video, api: api)
        }
        #elseif os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .navigationDestination(item: $channelDestination) { dest in
            ChannelView(channelId: dest.channelId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
            guard let channelId = note.userInfo?["channelId"] as? String, !channelId.isEmpty else { return }
            channelDestination = ChannelDestination(channelId: channelId)
        }
        .sheet(isPresented: $showFilterSheet) {
            SearchFilterSheet(current: vm.filter) { newFilter in
                vm.applyFilter(newFilter)
            }
        }
        .confirmationDialog(
            "Clear History",
            isPresented: $showClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { vm.clearHistory() }
            Button("Cancel", role: .cancel) {}
        }
        #if os(tvOS)
        .task(id: vm.query) {
            await vm.updateResults(for: vm.query)
        }
        #endif
        .onChange(of: isSearchFocused) { _, focused in
            // if focused { Task { await vm.updateSuggestions(for: vm.query) } }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        @Bindable var vm = vm
        return HStack(spacing: 8) {
            Image(systemName: AppSymbol.search)
                .foregroundStyle(.secondary)
            #if os(macOS)
            TextField("Search YouTube", text: $vm.query)
                .focused($isSearchFocused)
                .submitLabel(.search)
                .accessibilityIdentifier("search.bar")
                .onSubmit { vm.search(); isSearchFocused = false }
            #else
            TextField("Search YouTube", text: $vm.query)
                .focused($isSearchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .accessibilityIdentifier("search.bar")
                .textInputAutocapitalization(.never)
                .onSubmit { vm.search(); isSearchFocused = false }
            #endif
            if !vm.query.isEmpty {
                Button {
                    vm.query = ""
                } label: {
                    Image(systemName: AppSymbol.xmarkCircle)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search.clearButton")
            }
            Button {
                showFilterSheet = true
            } label: {
                Image(systemName: vm.filter.isDefault ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(vm.filter.isDefault ? .secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search.filterButton")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Active filter chips

    @ViewBuilder
    private var filterChipsRow: some View {
        if !vm.filter.isDefault {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if vm.filter.sortOrder != .relevance {
                        FilterChip(label: LocalizedStringKey(vm.filter.sortOrder.label)) {
                            var f = vm.filter; f.sortOrder = .relevance; vm.applyFilter(f)
                        }
                    }
                    if vm.filter.uploadDate != .anytime {
                        FilterChip(label: LocalizedStringKey(vm.filter.uploadDate.label)) {
                            var f = vm.filter; f.uploadDate = .anytime; vm.applyFilter(f)
                        }
                    }
                    if vm.filter.type != .any {
                        FilterChip(label: LocalizedStringKey(vm.filter.type.label)) {
                            var f = vm.filter; f.type = .any; vm.applyFilter(f)
                        }
                    }
                    if vm.filter.duration != .any {
                        FilterChip(label: LocalizedStringKey(vm.filter.duration.label)) {
                            var f = vm.filter; f.duration = .any; vm.applyFilter(f)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            Divider()
        }
    }

    // MARK: - Results

    private var resultsView: some View {
        let hideLiveShorts = store.settings.hideLiveShorts
        let hideVideoPremieres = store.settings.hideVideoPremieres
        let displayResults = vm.results
            .filter { !$0.isShort }
            .filter { !hideLiveShorts || !($0.isLive && $0.isShort) }
            .filter { !hideVideoPremieres || !$0.isUpcoming }
        return ScrollView {
            if vm.isLoading && vm.results.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
            VideoGridSection(
                videos: displayResults,
                onSelect: { video in
                    let captured = displayResults
                    Task { @MainActor in
                        await CurrentQueueStore.shared.replaceAll(with: captured)
                        let startIdx = captured.firstIndex(where: { $0.id == video.id }) ?? 0
                        let toPlay = await CurrentQueueStore.shared.videoAt(index: startIdx) ?? video
                        #if os(iOS)
                        playerRouter.open(video: toPlay, api: api)
                        #else
                        selectedVideo = toPlay
                        #endif
                    }
                },
                loadMore: vm.loadMore
            )
            if vm.isLoading && !vm.results.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
        .accessibilityIdentifier("search.results")
        #if os(iOS)
        .scrollDismissesKeyboard(.immediately)
        .contentShape(Rectangle())
        .onTapGesture { isSearchFocused = false }
        #endif
    }

    // MARK: - Suggestions list (history + recommended/live)

    #if os(tvOS)
    private var tvOSHistoryView: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 28) {
                if vm.history.isEmpty {
                    placeholderView
                        .frame(minHeight: 430)
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Recent")
                            .font(.largeTitle.weight(.bold))
                        Spacer()
                        Button("Clear History", role: .destructive) {
                            showClearHistoryConfirmation = true
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("search.history.clearAll")
                    }

                    SearchHistoryPreviewGrid(entries: Array(vm.history.prefix(12))) { entry in
                        vm.query = entry.query
                        vm.search()
                        isSearchFocused = false
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.top, 30)
            .padding(.bottom, 80)
        }
        .accessibilityIdentifier("search.suggestionsContainer")
    }
    #endif

    private var suggestionsListView: some View {
        let _ = vm.query.isEmpty ? "Recommended" : "Suggestions"
        return List {
            // History section — only shown when there are matching entries
            if !vm.filteredHistory.isEmpty {
                Section(header: Text("Recent").font(.caption).foregroundStyle(.secondary)) {
                    ForEach(vm.filteredHistory) { entry in
                        Button {
                            vm.query = entry.query
                            vm.search()
                            isSearchFocused = false
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text(entry.query)
                                    .foregroundStyle(.primary)
                                Spacer()
                                #if os(iOS)
                                Button {
                                    vm.removeHistoryEntry(entry.query)
                                } label: {
                                    Image(systemName: AppSymbol.xmark)
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(entry.query) from history")
                                #endif
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search.history.\(entry.query)")
                    }
                    Button(role: .destructive) {
                        vm.clearHistory()
                    } label: {
                        Text("Clear History")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("search.history.clearAll")
                }
            }

            // Suggestions / Recommended section (existing behaviour)
            // Section(header: Text(suggestionsHeader).font(.caption).foregroundStyle(.secondary)) {
            //     ForEach(vm.suggestions, id: \.self) { suggestion in
            //         Button {
            //             vm.query = suggestion
            //             vm.search()
            //             isSearchFocused = false
            //         } label: {
            //                         //             HStack(spacing: 12) {
            //                 Image(systemName: AppSymbol.search)
            //                     .foregroundStyle(.secondary)
            //                     .frame(width: 20)
            //                 Text(suggestion)
            //                     .foregroundStyle(.primary)
            //                 Spacer()
            //                 Button {
            //                     vm.query = suggestion
            //                 } label: {
            //                     Image(systemName: "arrow.up.left")
            //                         .foregroundStyle(.secondary)
            //                         .font(.caption)
            //                 }
            //                 .buttonStyle(.plain)
            //             }
            //             .contentShape(Rectangle())
            //         }
            //         .buttonStyle(.plain)
            //     }
            // }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("search.suggestionsContainer")
        // Tapping empty list space (outside a row) must dismiss the keyboard.
        // Task #202: the resultsView and noResultsView already had this gesture
        // but suggestionsListView (shown while keyboard is open) was missing it.
        // .contentShape(Rectangle()) makes the transparent empty space tappable.
        .contentShape(Rectangle())
        .onTapGesture { isSearchFocused = false }
    }

    private var placeholderView: some View {
        VStack(spacing: 16) {
            Image(systemName: AppSymbol.search)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("Search for videos, channels & playlists")
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noResultsView: some View {
        VStack(spacing: 16) {
            Image(systemName: AppSymbol.questionCircle)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No results for \"\(vm.query)\"")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        #if os(iOS)
        .contentShape(Rectangle())
        .onTapGesture { isSearchFocused = false }
        #endif
    }

    #if os(tvOS)
    private var searchPendingView: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            Text("Searching YouTube…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var searchErrorView: some View {
        VStack(spacing: 18) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("Couldn’t search YouTube")
                .font(.headline)
            if let error = vm.error {
                Text(error.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            Button("Try Again") {
                vm.retry()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(80)
    }
    #endif
}

#if os(tvOS)
// MARK: - tvOS search history previews

private struct SearchHistoryPreviewGrid: View {
    let entries: [SearchHistoryEntry]
    let onSelect: (SearchHistoryEntry) -> Void

    private let columnCount = 3
    private let cardWidth: CGFloat = 520

    private var rows: [[SearchHistoryEntry]] {
        stride(from: 0, to: entries.count, by: columnCount).map { start in
            Array(entries[start..<min(start + columnCount, entries.count)])
        }
    }

    var body: some View {
        Grid(horizontalSpacing: 32, verticalSpacing: 48) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                GridRow(alignment: .top) {
                    ForEach(rows[rowIndex]) { entry in
                        SearchHistoryPreviewCard(entry: entry) {
                            onSelect(entry)
                        }
                        .frame(width: cardWidth)
                    }

                    ForEach(rows[rowIndex].count..<columnCount, id: \.self) { _ in
                        Color.clear
                            .frame(width: cardWidth, height: 1)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }
}

private struct SearchHistoryPreviewCard: View {
    let entry: SearchHistoryEntry
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                SearchHistoryArtwork(videoIDs: entry.previewVideoIDs ?? [])
                    .frame(height: 292)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(
                                Color.white.opacity(isFocused ? 0.72 : (reduceTransparency ? 0.24 : 0.1)),
                                lineWidth: isFocused ? 3 : 1
                            )
                    }
                    .shadow(
                        color: isFocused ? Color.accentColor.opacity(0.32) : .black.opacity(0.24),
                        radius: isFocused ? 24 : 12,
                        y: isFocused ? 12 : 7
                    )

                HStack(spacing: 15) {
                    Image(systemName: AppSymbol.search)
                        .font(.title3.weight(.bold))
                        .frame(width: 54, height: 54)
                        .foregroundStyle(.white)
                        .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 13))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.query)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(entry.timestamp, style: .relative)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.035 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isFocused)
        .accessibilityIdentifier("search.history.\(entry.query)")
        .accessibilityLabel(entry.query)
    }
}

private struct SearchHistoryArtwork: View {
    let videoIDs: [String]

    private var displayedIDs: [String] {
        Array(videoIDs.prefix(3))
    }

    var body: some View {
        GeometryReader { proxy in
            if let firstID = displayedIDs.first {
                HStack(spacing: 4) {
                    HistoryPreviewImage(videoID: firstID)
                        .frame(width: displayedIDs.count == 1 ? proxy.size.width : proxy.size.width * 0.665)

                    if displayedIDs.count > 1 {
                        VStack(spacing: 4) {
                            HistoryPreviewImage(videoID: displayedIDs[1])
                            if displayedIDs.count > 2 {
                                HistoryPreviewImage(videoID: displayedIDs[2])
                            }
                        }
                    }
                }
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.24, green: 0.035, blue: 0.055), .black],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 72, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.76))
                }
            }
        }
        .background(Color.black.opacity(0.55))
    }
}

private struct HistoryPreviewImage: View {
    let videoID: String

    @StateObject private var loader = ThumbnailImageLoader()

    private var candidates: [URL] {
        [
            "https://i.ytimg.com/vi/\(videoID)/maxresdefault.jpg",
            "https://i.ytimg.com/vi/\(videoID)/hq720.jpg",
            "https://i.ytimg.com/vi/\(videoID)/sddefault.jpg",
            "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg",
            "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg",
        ].compactMap(URL.init(string:))
    }

    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if loader.isLoading {
                ProgressView()
            } else {
                Image(systemName: "play.rectangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: videoID) {
            loader.load(candidates: candidates, videoId: videoID)
        }
        .onDisappear { loader.cancel() }
    }
}
#endif

// MARK: - FilterChip

private struct FilterChip: View {
    let label: LocalizedStringKey
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
            Button(action: onRemove) {
                Image(systemName: AppSymbol.xmark)
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.tint.opacity(0.15), in: Capsule())
        .foregroundStyle(.tint)
    }
}

// MARK: - SearchFilterSheet

struct SearchFilterSheet: View {
    let current: SearchFilter
    let onApply: (SearchFilter) -> Void

    @State private var draft: SearchFilter
    @Environment(\.dismiss) private var dismiss

    init(current: SearchFilter, onApply: @escaping (SearchFilter) -> Void) {
        self.current = current
        self.onApply = onApply
        _draft = State(initialValue: current)
    }

    var body: some View {
        #if os(tvOS)
        NavigationStack {
            List {
                Section("Sort by") {
                    Picker("Sort", selection: $draft.sortOrder) {
                        ForEach(SearchFilter.SortOrder.allCases, id: \.self) { order in
                            Text(LocalizedStringKey(order.label)).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                }

                Section("Upload date") {
                    Picker("Upload date", selection: $draft.uploadDate) {
                        ForEach(SearchFilter.UploadDate.allCases, id: \.self) { date in
                            Text(LocalizedStringKey(date.label)).tag(date)
                        }
                    }
                    .pickerStyle(.inline)
                }

                Section(String(localized: "search.filter.type", bundle: .module)) {
                    Picker(String(localized: "search.filter.type", bundle: .module), selection: $draft.type) {
                        ForEach(SearchFilter.VideoType.allCases, id: \.self) { type in
                            Text(LocalizedStringKey(type.label)).tag(type)
                        }
                    }
                    .pickerStyle(.inline)
                }

                Section("Duration") {
                    Picker("Duration", selection: $draft.duration) {
                        ForEach(SearchFilter.Duration.allCases, id: \.self) { dur in
                            Text(LocalizedStringKey(dur.label)).tag(dur)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle("Search filters")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(draft)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") { draft = .default }
                        .disabled(draft.isDefault)
                }
            }
        }
        #else
        NavigationStack {
            Form {
                Section("Sort by") {
                    Picker("Sort", selection: $draft.sortOrder) {
                        ForEach(SearchFilter.SortOrder.allCases, id: \.self) { order in
                            Text(LocalizedStringKey(order.label)).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Upload date") {
                    Picker("Upload date", selection: $draft.uploadDate) {
                        ForEach(SearchFilter.UploadDate.allCases, id: \.self) { date in
                            Text(LocalizedStringKey(date.label)).tag(date)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section(String(localized: "search.filter.type", bundle: .module)) {
                    Picker(String(localized: "search.filter.type", bundle: .module), selection: $draft.type) {
                        ForEach(SearchFilter.VideoType.allCases, id: \.self) { type in
                            Text(LocalizedStringKey(type.label)).tag(type)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Duration") {
                    Picker("Duration", selection: $draft.duration) {
                        ForEach(SearchFilter.Duration.allCases, id: \.self) { dur in
                            Text(LocalizedStringKey(dur.label)).tag(dur)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("Search filters")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(draft)
                        dismiss()
                    }
                }
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) {
                    Button("Reset") { draft = .default }
                        .disabled(draft.isDefault)
                }
                #else
                ToolbarItem(placement: .automatic) {
                    Button("Reset") { draft = .default }
                        .disabled(draft.isDefault)
                }
                #endif
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            #endif
        }
        #endif
    }
}
