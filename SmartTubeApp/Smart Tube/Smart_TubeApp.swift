import SwiftUI
import SmartTubeIOS
import SmartTubeIOSCore

/// tvOS entry point for SmartTube.
/// The device-code + QR sign-in flow is natively designed for Apple TV —
/// the user reads a code on screen and activates on their phone at yt.be/activate.
@main
struct SmartTubeTVApp: App {
    @State private var api: InnerTubeAPI
    @State private var authService: AuthService
    @State private var browseViewModel: BrowseViewModel
    @State private var settingsStore: SettingsStore
    /// Shared download service — required by RootView and VideoCardView even on
    /// tvOS (where downloads are disabled in UI). Must be present in the environment
    /// or SwiftUI throws a fatal "No Observable object of type VideoDownloadService"
    /// error at launch.
    @State private var cardDownloadService: VideoDownloadService

    private var diagnosticVideoID: String? {
        let argumentPrefix = "--uitesting-deeplink-video="
        let argumentValue = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix(argumentPrefix) })
            .map { String($0.dropFirst(argumentPrefix.count)) }
        return argumentValue
            ?? ProcessInfo.processInfo.environment["PLAYBACK_DIAGNOSTIC_VIDEO_ID"]
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
        _cardDownloadService = State(initialValue: VideoDownloadService(api: api))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let diagnosticVideoID {
                    PlayerView(
                        video: Video(id: diagnosticVideoID, title: diagnosticVideoID, channelTitle: ""),
                        api: api
                    )
                } else {
                    RootView()
                }
            }
                .environment(authService)
                .environment(browseViewModel)
                .environment(settingsStore)
                .environment(\.innerTubeAPI, api)
                .environment(cardDownloadService)
                .onChange(of: authService.accessToken, initial: true) { _, newToken in
                    Task {
                        await api.setAuthToken(newToken)
                        await browseViewModel.updateAuthToken(newToken)
                    }
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
