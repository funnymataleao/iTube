import SwiftUI
import SmartTubeIOS
import SmartTubeIOSCore

/// tvOS entry point for iTube.
/// The device-code + QR sign-in flow is natively designed for Apple TV —
/// the user reads a code on screen and activates on their phone at yt.be/activate.
@main
struct ITubeTVApp: App {
    @State private var api: InnerTubeAPI
    @State private var authService: AuthService
    @State private var browseViewModel: BrowseViewModel
    @State private var settingsStore: SettingsStore
    @State private var accessStore: AppAccessStore
    @State private var authSyncTask: Task<Void, Never>? = nil
    @State private var authSyncRevision: UInt = 0
    /// Shared download service — required by RootView and VideoCardView even on
    /// tvOS (where downloads are disabled in UI). Must be present in the environment
    /// or SwiftUI throws a fatal "No Observable object of type VideoDownloadService"
    /// error at launch.
    @State private var cardDownloadService: VideoDownloadService

    private var diagnosticVideoID: String? {
        #if DEBUG
        let argumentPrefix = "--uitesting-deeplink-video="
        let argumentValue = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix(argumentPrefix) })
            .map { String($0.dropFirst(argumentPrefix.count)) }
        return argumentValue
            ?? ProcessInfo.processInfo.environment["PLAYBACK_DIAGNOSTIC_VIDEO_ID"]
        #else
        return nil
        #endif
    }

    private var diagnosticChannelID: String? {
        #if DEBUG
        let argumentPrefix = "--uitesting-deeplink-channel="
        return ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix(argumentPrefix) })
            .map { String($0.dropFirst(argumentPrefix.count)) }
        #else
        return nil
        #endif
    }

    init() {
        let settingsStore = SettingsStore()
        if !UserDefaults.standard.bool(forKey: "personalTube.tvOS.didConfigure") {
            settingsStore.settings.hideShorts = true
            settingsStore.settings.enabledSections = [.home, .subscriptions, .history]
            settingsStore.settings.sponsorBlockActions[.sponsor] = .skip
            settingsStore.settings.sponsorBlockActions[.selfPromo] = .skip
            settingsStore.settings.sponsorBlockActions[.intro] = .skip
            settingsStore.settings.sponsorBlockActions[.outro] = .skip
            UserDefaults.standard.set(true, forKey: "personalTube.tvOS.didConfigure")
        }
        let poTokenProvider: (any PoTokenProvider)? = {
            if let url = settingsStore.settings.poTokenServiceURL {
                return ServerPoTokenProvider(serviceURL: url)
            }
            return BotGuardClient()
        }()
        let api = InnerTubeAPI(authToken: nil, poTokenProvider: poTokenProvider)
        _api                 = State(initialValue: api)
        _authService         = State(initialValue: AuthService())
        _browseViewModel     = State(initialValue: BrowseViewModel(api: api))
        _settingsStore       = State(initialValue: settingsStore)
        _accessStore         = State(initialValue: AppAccessStore())
        _cardDownloadService = State(initialValue: VideoDownloadService(api: api))

        #if DEBUG
        if let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--uitesting-force-stream-method=")
        }) {
            let method = String(
                argument.dropFirst("--uitesting-force-stream-method=".count)
            )
            if StreamMethodProbeSupport.knownMethods.contains(method) {
                StreamMethodProbeSupport.forcedStreamMethod = method
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TVAccessGate {
                Group {
                    if let diagnosticChannelID {
                        NavigationStack {
                            ChannelView(channelId: diagnosticChannelID)
                        }
                    } else if let diagnosticVideoID {
                        PlayerView(
                            video: Video(id: diagnosticVideoID, title: diagnosticVideoID, channelTitle: ""),
                            api: api
                        )
                    } else {
                        RootView()
                    }
                }
            }
                .environment(authService)
                .environment(browseViewModel)
                .environment(settingsStore)
                .environment(accessStore)
                .environment(\.innerTubeAPI, api)
                .environment(cardDownloadService)
                .onChange(of: authService.accessToken, initial: true) { _, newToken in
                    let effectiveToken = newToken.flatMap { $0.isEmpty ? nil : $0 }
                    authSyncRevision &+= 1
                    let revision = authSyncRevision
                    authSyncTask?.cancel()
                    authSyncTask = Task { @MainActor in
                        // BrowseViewModel owns this app's shared API and repairs
                        // overlapping token writes with its own revision guard.
                        await browseViewModel.updateAuthToken(effectiveToken)
                        guard !Task.isCancelled, authSyncRevision == revision else { return }

                        await VideoPreloadCache.shared.setAuthToken(effectiveToken)
                        guard !Task.isCancelled, authSyncRevision == revision else {
                            let latest = authService.accessToken.flatMap { $0.isEmpty ? nil : $0 }
                            await VideoPreloadCache.shared.setAuthToken(latest)
                            if latest == nil {
                                await VideoPreloadCache.shared.evictAuthSensitiveData()
                            }
                            return
                        }

                        if effectiveToken == nil {
                            // Logout can happen from Settings with no live player.
                            await VideoPreloadCache.shared.evictAuthSensitiveData()
                        }
                    }
                }
                .onChange(of: authService.accountPageId, initial: true) { _, pageId in
                    Task { await api.setAccountPageId(pageId) }
                }
                .onChange(of: authService.sapisid, initial: true) { _, newSapisid in
                    Task { await api.setSAPISID(newSapisid) }
                }
                .onChange(of: settingsStore.settings.enabledSections) { _, newSections in
                    browseViewModel.configureSections(newSections)
                }
                .onChange(of: settingsStore.settings.historyState, initial: true) { _, newState in
                    browseViewModel.updateHistoryEnabled(newState == .enabled)
                }
        }
    }
}
