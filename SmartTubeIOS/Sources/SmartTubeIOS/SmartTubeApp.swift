import SwiftUI
import SmartTubeIOSCore

/// App entry point – supports iOS 17+, iPadOS 17+, macOS 14+.
struct SmartTubeApp: App {
    @State private var api: InnerTubeAPI
    @State private var authService: AuthService
    @State private var browseViewModel: BrowseViewModel
    @State private var settingsStore: SettingsStore
    @State private var authSyncTask: Task<Void, Never>? = nil
    @State private var authSyncRevision: UInt = 0
    /// Shared download service used by video cards. Lives at the app scope so
    /// the download task is not orphaned when a card view leaves the hierarchy
    /// (e.g. after a context menu dismiss). PlayerView creates its own isolated
    /// service instance and is unaffected.
    @State private var cardDownloadService: VideoDownloadService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let api = InnerTubeAPI()
        _api = State(initialValue: api)
        _authService = State(initialValue: AuthService())
        _browseViewModel = State(initialValue: BrowseViewModel(api: api))
        _settingsStore = State(initialValue: SettingsStore())
        _cardDownloadService = State(initialValue: VideoDownloadService(api: api))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authService)
                .environment(browseViewModel)
                .environment(settingsStore)
                .environment(\.innerTubeAPI, api)
                .environment(cardDownloadService)
                .environment(DownloadStore.shared)
                .onChange(of: authService.accessToken, initial: true) { _, newToken in
                    authSyncRevision &+= 1
                    let revision = authSyncRevision
                    authSyncTask?.cancel()
                    authSyncTask = Task { @MainActor in
                        // BrowseViewModel owns the shared app API and protects its
                        // own token propagation with a latest-value-wins revision.
                        await browseViewModel.updateAuthToken(newToken)
                        guard !Task.isCancelled, authSyncRevision == revision else { return }

                        await VideoPreloadCache.shared.setAuthToken(newToken)
                        guard !Task.isCancelled, authSyncRevision == revision else {
                            let latest = authService.accessToken.flatMap { $0.isEmpty ? nil : $0 }
                            await VideoPreloadCache.shared.setAuthToken(latest)
                            if latest == nil {
                                await VideoPreloadCache.shared.evictAuthSensitiveData()
                            }
                            return
                        }

                        if newToken == nil {
                            // Sign-out may happen with no live player, so the app
                            // root is the authoritative cache invalidation point.
                            await VideoPreloadCache.shared.evictAuthSensitiveData()
                        }
                    }
                }
                .onChange(of: authService.accountPageId, initial: true) { _, pageId in
                    Task { await api.setAccountPageId(pageId) }
                }
                .onChange(of: settingsStore.settings.enabledSections) { _, newSections in
                    browseViewModel.configureSections(newSections)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await authService.refreshIfNeeded()
                    authService.handleForeground()
                }
            }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        #endif
    }
}
