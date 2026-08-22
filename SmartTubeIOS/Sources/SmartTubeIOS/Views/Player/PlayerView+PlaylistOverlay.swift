import SwiftUI
import SmartTubeIOSCore
#if canImport(UIKit)
import UIKit
#endif

#if os(tvOS)

private enum PlaylistPickerFocus: Hashable {
    case create
    case cancel
    case confirm
    case playlist(String)
}

private let playlistPanelShape = RoundedRectangle(cornerRadius: 28, style: .continuous)

struct TVPlaylistPickerOverlay: View {
    let viewModel: PlaybackViewModel
    let onDismiss: @MainActor () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var playlists: [PlaylistInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isCreatingPlaylist = false
    @State private var playlistName = ""
    @State private var busyID: String?
    @FocusState private var focusedItem: PlaylistPickerFocus?
    @FocusState private var nameFieldFocused: Bool
    @Namespace private var focusNamespace

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()

            Group {
                if isCreatingPlaylist {
                    createPanel
                } else {
                    pickerPanel
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 34)
            .frame(width: 560)
            .background { panelBackground }
        }
        .focusScope(focusNamespace)
        .ignoresSafeArea()
        .task { await loadPlaylists() }
        .onExitCommand { handleBack() }
        .disabled(busyID != nil)
    }

    private var pickerPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add to Playlist")
                .font(.headline.weight(.semibold))
                .tracking(-0.3)
                .padding(.bottom, 4)

            Button(action: beginCreatePlaylist) {
                rowLabel(title: "New Playlist", systemImage: "plus")
            }
            .buttonStyle(TVPlaylistRowStyle(reduceMotion: reduceMotion))
            .focused($focusedItem, equals: .create)
            .prefersDefaultFocus(in: focusNamespace)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if playlists.isEmpty {
                Text("No playlists yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 10) {
                            ForEach(playlists) { playlist in
                                Button {
                                    addCurrentVideo(to: playlist)
                                } label: {
                                    rowLabel(
                                        title: playlist.title,
                                        accessory: busyID == playlist.id ? nil : playlist.videoCount.map(String.init),
                                        showsProgress: busyID == playlist.id
                                    )
                                }
                                .buttonStyle(TVPlaylistRowStyle(reduceMotion: reduceMotion))
                                .focused($focusedItem, equals: .playlist(playlist.id))
                                .id(playlist.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                    .scrollClipDisabled()
                    .scrollIndicators(.hidden)
                    .focusSection()
                    .frame(maxHeight: 420)
                    .onChange(of: focusedItem) { _, newValue in
                        guard case .playlist(let id) = newValue else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var createPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("New Playlist")
                .font(.headline.weight(.semibold))
                .tracking(-0.3)

            TextField("Playlist name", text: $playlistName)
                .font(.body)
                .focused($nameFieldFocused)
                .submitLabel(.done)
                .onSubmit { createPlaylist() }

            HStack(spacing: 14) {
                Button("Cancel") {
                    isCreatingPlaylist = false
                    playlistName = ""
                    focusedItem = .create
                }
                .buttonStyle(TVGlassCapsuleButtonStyle(prominent: false, reduceMotion: reduceMotion))
                .focused($focusedItem, equals: .cancel)
                .frame(maxWidth: .infinity)

                Button("Create") { createPlaylist() }
                    .buttonStyle(TVGlassCapsuleButtonStyle(prominent: true, reduceMotion: reduceMotion))
                    .focused($focusedItem, equals: .confirm)
                    .frame(maxWidth: .infinity)
                    .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busyID != nil)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { nameFieldFocused = true }
    }

    private func rowLabel(title: String, systemImage: String? = nil, accessory: String? = nil, showsProgress: Bool = false) -> some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
            }
            Text(title)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsProgress {
                ProgressView().controlSize(.mini)
            } else if let accessory {
                Text(accessory)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    @ViewBuilder
    private var panelBackground: some View {
        if #available(tvOS 26.0, *), !reduceTransparency {
            Color.clear.glassEffect(.regular, in: playlistPanelShape)
        } else if reduceTransparency {
            playlistPanelShape.fill(Color.black.opacity(0.88))
        } else {
            playlistPanelShape.fill(.ultraThinMaterial)
        }
    }

    private func handleBack() {
        if isCreatingPlaylist {
            isCreatingPlaylist = false
            playlistName = ""
            focusedItem = .create
        } else {
            onDismiss()
        }
    }

    private func beginCreatePlaylist() {
        errorMessage = nil
        playlistName = ""
        isCreatingPlaylist = true
    }

    private func loadPlaylists() async {
        isLoading = true
        errorMessage = nil
        do {
            playlists = try await viewModel.fetchPlaylistsForPicker()
            focusedItem = .create
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
        isLoading = false
    }

    private func addCurrentVideo(to playlist: PlaylistInfo) {
        guard busyID == nil else { return }
        busyID = playlist.id
        errorMessage = nil
        Task { @MainActor in
            defer { busyID = nil }
            do {
                try await viewModel.addCurrentVideo(to: playlist)
                onDismiss()
            } catch {
                errorMessage = friendlyMessage(for: error)
            }
        }
    }

    private func createPlaylist() {
        let title = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, busyID == nil else { return }
        busyID = "create"
        errorMessage = nil
        Task { @MainActor in
            defer { busyID = nil }
            do {
                let playlist = try await viewModel.createPlaylistAndAddCurrentVideo(title: title)
                playlists.insert(playlist, at: 0)
                onDismiss()
            } catch {
                errorMessage = friendlyMessage(for: error)
            }
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        if let apiError = error as? APIError {
            switch apiError {
            case .notAuthenticated:
                return String(localized: "Sign in to use playlists.", bundle: .module)
            case .unavailable(let reason) where !reason.isEmpty:
                return reason
            default:
                break
            }
        }
        return String(localized: "Couldn't update the playlist. Try again.", bundle: .module)
    }
}

private struct TVGlassCapsuleButtonStyle: ButtonStyle {
    var prominent: Bool
    var reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        TVGlassCapsuleButtonStyleBody(
            configuration: configuration,
            prominent: prominent,
            reduceMotion: reduceMotion
        )
    }
}

private struct TVGlassCapsuleButtonStyleBody: View {
    let configuration: ButtonStyle.Configuration
    var prominent: Bool
    var reduceMotion: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .background { capsuleBackground }
            .scaleEffect(reduceMotion ? 1 : (isFocused ? 1.03 : 1))
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
    }

    @ViewBuilder
    private var capsuleBackground: some View {
        if #available(tvOS 26.0, *), !reduceTransparency {
            Capsule().glassEffect(isFocused || prominent ? .regular.interactive() : .regular)
        } else if reduceTransparency {
            Capsule().fill(Color.white.opacity(isFocused ? 0.22 : (prominent ? 0.16 : 0.10)))
        } else {
            Capsule().fill(.ultraThinMaterial)
        }
    }
}

private struct TVPlaylistRowStyle: ButtonStyle {
    var reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        TVPlaylistRowStyleBody(configuration: configuration, reduceMotion: reduceMotion)
    }
}

private struct TVPlaylistRowStyleBody: View {
    let configuration: ButtonStyle.Configuration
    var reduceMotion: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundStyle(.primary)
            .background {
                if isFocused {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.16))
                }
            }
            .scaleEffect(reduceMotion ? 1 : (isFocused ? 1.02 : 1))
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
    }
}

@MainActor
final class TVPlaylistOverlayHost: UIHostingController<TVPlaylistPickerOverlay> {
    var onHostDismissed: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onHostDismissed?()
        }
    }
}

#endif
