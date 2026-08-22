import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - VideoPublishAgeParserTests
//
// Tests for task #97: video publish age (publishedAt) extraction in parser functions.
//
// Root cause: parseVideoRenderer and parseLockupViewModel hardcoded publishedAt: nil.
// parseTileRenderer already extracted it correctly (TV client). These tests verify the
// fix extracts the relative-date string from the JSON and populates Video.publishedAt.
//
// All assertions are pure value transforms — no SwiftUI, no network.

// MARK: - Helpers

/// Wraps a videoRenderer in the minimal sectionListRenderer structure for parseVideoGroupForTesting.
private func makeVideoRendererAgeResponse(_ renderer: [String: Any]) -> [String: Any] {
    [
        "contents": [
            "sectionListRenderer": [
                "contents": [
                    [
                        "itemSectionRenderer": [
                            "contents": [["videoRenderer": renderer]]
                        ]
                    ]
                ]
            ]
        ]
    ]
}

/// Wraps a lockupViewModel in the minimal structure that the walker handles at the dict level.
private func makeLockupViewModelAgeResponse(_ lockup: [String: Any]) -> [String: Any] {
    [
        "contents": [
            "sectionListRenderer": [
                "contents": [
                    [
                        "itemSectionRenderer": [
                            "contents": [["lockupViewModel": lockup]]
                        ]
                    ]
                ]
            ]
        ]
    ]
}

/// Returns the approximate expected Date for a relative string like "2 years ago".
private func approximateDate(yearsAgo: Int) -> Date {
    Date(timeIntervalSinceNow: -TimeInterval(yearsAgo * 365 * 86_400))
}

// MARK: - parseVideoRenderer publishedAt

@Suite("Task #97 — parseVideoRenderer publishedAt extraction")
struct VideoRendererPublishAgeTests {

    // A minimal valid videoRenderer dict with a publishedTimeText.simpleText field.
    private func makeRenderer(publishedTimeText: Any?) -> [String: Any] {
        var r: [String: Any] = [
            "videoId": "testvidid",
            "title": ["simpleText": "Test Video"],
            "ownerText": ["runs": [["text": "Test Channel",
                                    "navigationEndpoint": ["browseEndpoint": ["browseId": "UCtest"]]]]],
            "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/testvidid/hqdefault.jpg"]]],
        ]
        if let pubText = publishedTimeText {
            r["publishedTimeText"] = pubText
        }
        return r
    }

    @Test("parseVideoRenderer with simpleText publishedTimeText populates publishedAt")
    func videoRenderer_simpleText_populatesPublishedAt() async throws {
        let response = makeVideoRendererAgeResponse(makeRenderer(
            publishedTimeText: ["simpleText": "2 years ago"]
        ))
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = try #require(group.videos.first, "Expected at least one video from response")
        let publishedAt = try #require(video.publishedAt, "publishedAt should be non-nil for '2 years ago'")
        let expectedDate = approximateDate(yearsAgo: 2)
        // Allow 7-day tolerance for calendar approximations in parseRelativeDate.
        #expect(abs(publishedAt.timeIntervalSince(expectedDate)) < 7 * 86_400,
                "publishedAt should be approximately 2 years ago")
    }

    @Test("parseVideoRenderer with runs publishedTimeText populates publishedAt")
    func videoRenderer_runsText_populatesPublishedAt() async throws {
        let response = makeVideoRendererAgeResponse(makeRenderer(
            publishedTimeText: ["runs": [["text": "3 months ago"]]]
        ))
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = try #require(group.videos.first, "Expected at least one video from response")
        #expect(video.publishedAt != nil,
                "publishedAt should be non-nil for runs-format '3 months ago'")
    }

    @Test("parseVideoRenderer treats Today as the newest publish date")
    func videoRenderer_today_populatesCurrentPublishedAt() async throws {
        let response = makeVideoRendererAgeResponse(makeRenderer(
            publishedTimeText: ["simpleText": "Today"]
        ))
        let beforeParsing = Date()
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = try #require(group.videos.first, "Expected at least one video from response")
        let publishedAt = try #require(video.publishedAt, "publishedAt should be non-nil for 'Today'")

        #expect(publishedAt >= beforeParsing.addingTimeInterval(-2),
                "Today should sort with current uploads rather than behind older videos")
        #expect(publishedAt <= Date().addingTimeInterval(2),
                "Today should not produce a future publish date")
    }

    @Test("parseVideoRenderer treats Yesterday as one day old")
    func videoRenderer_yesterday_populatesRecentPublishedAt() async throws {
        let response = makeVideoRendererAgeResponse(makeRenderer(
            publishedTimeText: ["simpleText": "Yesterday"]
        ))
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = try #require(group.videos.first, "Expected at least one video from response")
        let publishedAt = try #require(video.publishedAt, "publishedAt should be non-nil for 'Yesterday'")
        let expectedDate = Date(timeIntervalSinceNow: -86_400)

        #expect(abs(publishedAt.timeIntervalSince(expectedDate)) < 2,
                "Yesterday should sort approximately one day before current uploads")
    }

    @Test("parseVideoRenderer without publishedTimeText leaves publishedAt nil")
    func videoRenderer_noPublishedTimeText_publishedAtIsNil() async throws {
        let response = makeVideoRendererAgeResponse(makeRenderer(publishedTimeText: nil))
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = try #require(group.videos.first, "Expected at least one video from response")
        #expect(video.publishedAt == nil,
                "publishedAt should be nil when publishedTimeText is absent from JSON")
    }
}

// MARK: - parseLockupViewModel publishedAt

@Suite("Task #97 — parseLockupViewModel publishedAt extraction")
struct LockupViewModelPublishAgeTests {

    /// Builds a minimal valid lockupViewModel with configurable metadataRows.
    private func makeLockup(metadataRows: [[String: Any]]) -> [String: Any] {
        [
            "rendererContext": [
                "commandContext": [
                    "onTap": [
                        "innertubeCommand": [
                            "watchEndpoint": ["videoId": "lockupvid"]
                        ]
                    ]
                ]
            ],
            "metadata": [
                "lockupMetadataViewModel": [
                    "title": ["content": "Lockup Video"],
                    "metadata": [
                        "contentMetadataViewModel": [
                            "metadataRows": metadataRows
                        ]
                    ]
                ]
            ],
            "contentImage": [
                "thumbnailViewModel": [
                    "image": ["thumbnails": [["url": "https://i.ytimg.com/vi/lockupvid/hqdefault.jpg"]]]
                ]
            ]
        ]
    }

    @Test("parseLockupViewModel extracts publishedAt from second metadataRow")
    func lockupViewModel_secondRow_populatesPublishedAt() async throws {
        let rows: [[String: Any]] = [
            // Row 0: channel name
            ["metadataParts": [["text": ["content": "Channel Name"]]]],
            // Row 1: view count + published date (both in same row — mirrors real YouTube layout)
            ["metadataParts": [
                ["text": ["content": "1.2M views"]],
                ["text": ["content": "2 years ago"]]
            ]]
        ]
        let response = makeLockupViewModelAgeResponse(makeLockup(metadataRows: rows))
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = try #require(group.videos.first, "Expected at least one video from lockupViewModel response")
        let publishedAt = try #require(video.publishedAt, "publishedAt should be non-nil when metadataRows contain '2 years ago'")
        let expectedDate = approximateDate(yearsAgo: 2)
        #expect(abs(publishedAt.timeIntervalSince(expectedDate)) < 7 * 86_400,
                "publishedAt should be approximately 2 years ago")
    }

    @Test("parseLockupViewModel with no relative-date text leaves publishedAt nil")
    func lockupViewModel_noRelativeDate_publishedAtIsNil() async throws {
        let rows: [[String: Any]] = [
            ["metadataParts": [["text": ["content": "Channel Name"]]]],
            ["metadataParts": [["text": ["content": "1.2M views"]]]]
            // No relative date in any row
        ]
        let response = makeLockupViewModelAgeResponse(makeLockup(metadataRows: rows))
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = try #require(group.videos.first, "Expected at least one video from lockupViewModel response")
        #expect(video.publishedAt == nil,
                "publishedAt should be nil when no row contains a relative date string")
    }

    @Test("parseLockupViewModel preserves coarse Today text for honest formatting")
    func lockupViewModel_today_preservesRawText() async throws {
        let rows: [[String: Any]] = [
            ["metadataParts": [["text": ["content": "Channel Name"]]]],
            ["metadataParts": [["text": ["content": "Today"]]]]
        ]
        let response = makeLockupViewModelAgeResponse(makeLockup(metadataRows: rows))
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = try #require(group.videos.first)

        #expect(video.publishedAt != nil)
        #expect(video.publishedTimeText == "Today")
        #expect(VideoPublishAgeFormatter.label(for: video) == nil)
    }
}

@Suite("Task #97 — section header publish-age fallback")
struct SectionHeaderPublishAgeTests {
    @Test("Today section header is preserved instead of becoming a fabricated minute")
    func todaySectionHeaderPreservesRawText() async throws {
        let tile: [String: Any] = [
            "contentType": "TILE_CONTENT_TYPE_VIDEO",
            "onSelectCommand": ["watchEndpoint": ["videoId": "section-today"]],
            "metadata": [
                "tileMetadataRenderer": [
                    "title": ["simpleText": "Section Video"]
                ]
            ]
        ]
        let response: [String: Any] = [
            "contents": [
                "sectionListRenderer": [
                    "contents": [[
                        "itemSectionRenderer": [
                            "header": [
                                "itemSectionHeaderRenderer": [
                                    "title": ["simpleText": "Today"]
                                ]
                            ],
                            "contents": [["tileRenderer": tile]]
                        ]
                    ]]
                ]
            ]
        ]

        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(response, title: nil)
        let video = try #require(group.videos.first)

        #expect(video.publishedAt != nil)
        #expect(video.publishedTimeText == "Today")
        #expect(VideoPublishAgeFormatter.label(for: video) == nil)
    }
}
