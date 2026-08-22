#if os(iOS)
import AppIntents
import UIKit
import SmartTubeIOSCore

// MARK: - OpenYouTubeVideoIntent

/// Opens a YouTube video directly in iTube from Siri or the Shortcuts app.
///
/// Siri phrases (registered via ``SmartTubeShortcuts``):
///   - "Watch on iTube"
///   - "Open YouTube video in iTube"
///   - "Play in iTube"
///
/// The intent extracts the video ID using ``YouTubeLinkHandler`` and fires the
/// existing `smarttube://video/<id>` deep link, which ``AppEntry.handleOpenURL``
/// already handles — no new playback wiring required.
struct OpenYouTubeVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Open YouTube Video in iTube"
    static let description = IntentDescription(
        "Opens a YouTube video or Short URL directly in iTube."
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "YouTube URL", description: "A YouTube video, Short, or youtu.be URL.")
    var url: URL

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let videoID = YouTubeLinkHandler.videoID(from: url) else {
            throw SmartTubeIntentError.notYouTubeURL
        }
        guard let deepLink = URL(string: "smarttube://video/\(videoID)") else {
            throw SmartTubeIntentError.invalidURL
        }
        await UIApplication.shared.open(deepLink)
        return .result()
    }
}

// MARK: - SmartTubeShortcuts

/// Registers app shortcuts so they surface in Spotlight and the Shortcuts app
/// automatically — no user setup required (iOS 16.4+).
struct SmartTubeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenYouTubeVideoIntent(),
            phrases: [
                "Open YouTube video in \(.applicationName)",
                "Watch on \(.applicationName)",
                "Play in \(.applicationName)"
            ],
            shortTitle: "Open in iTube",
            systemImageName: "play.rectangle"
        )
    }
}

// MARK: - SmartTubeIntentError

enum SmartTubeIntentError: LocalizedError {
    case invalidURL
    case notYouTubeURL

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Could not build an iTube deep link."
        case .notYouTubeURL: "The URL doesn't appear to be a YouTube video link."
        }
    }
}
#endif
