import Foundation
import Testing
@testable import SmartTubeIOSCore

@Suite("Video publish age formatter")
struct VideoPublishAgeFormatterTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let locale = Locale(identifier: "en_US")

    @Test("Recent uploads use minutes and hours instead of Today")
    func recentUploadsNeverCollapseToToday() {
        #expect(label(secondsAgo: 20) == expectedRelative(1, component: .minute))
        #expect(label(secondsAgo: 60) == expectedRelative(1, component: .minute))
        #expect(label(secondsAgo: 12 * 60) == expectedRelative(12, component: .minute))
        #expect(label(secondsAgo: 3_599) == expectedRelative(59, component: .minute))
        #expect(label(secondsAgo: 3_600) == expectedRelative(1, component: .hour))
        #expect(label(secondsAgo: 86_399) == expectedRelative(23, component: .hour))
    }

    @Test("Day boundary remains compact and localized")
    func dayBoundary() {
        #expect(label(secondsAgo: 24 * 60 * 60) == expectedRelative(1, component: .day))
        #expect(label(secondsAgo: 4 * 24 * 60 * 60) == expectedRelative(4, component: .day))
    }

    @Test("Exact metadata wins over a coarse Today feed label")
    func exactTimestampWinsOverToday() {
        let video = Video(
            id: "exact-today",
            title: "Exact",
            channelTitle: "Channel",
            publishedAt: now,
            exactPublishedAt: now.addingTimeInterval(-2 * 3_600),
            publishedTimeText: "Today"
        )

        #expect(
            VideoPublishAgeFormatter.label(for: video, relativeTo: now, locale: locale)
                == expectedRelative(2, component: .hour)
        )
    }

    @Test("Coarse Today is not fabricated as one minute")
    func coarseTodayWithoutExactTimestampIsOmitted() {
        let video = Video(
            id: "coarse-today",
            title: "Coarse",
            channelTitle: "Channel",
            publishedAt: now,
            publishedTimeText: "Today"
        )

        #expect(VideoPublishAgeFormatter.label(for: video, relativeTo: now, locale: locale) == nil)
    }

    @Test("Localized coarse Today label is not fabricated as one minute")
    func localizedCoarseTodayWithoutExactTimestampIsOmitted() {
        let video = Video(
            id: "coarse-today-ru",
            title: "Coarse",
            channelTitle: "Channel",
            publishedAt: now,
            publishedTimeText: "Сегодня"
        )

        #expect(
            VideoPublishAgeFormatter.label(
                for: video,
                relativeTo: now,
                locale: Locale(identifier: "ru_RU")
            ) == nil
        )
    }

    @Test("Word-based relative labels are not mistaken for Today")
    func wordBasedRelativeLabelRemainsVisible() {
        let video = Video(
            id: "word-based-age",
            title: "Word based",
            channelTitle: "Channel",
            publishedTimeText: "an hour ago"
        )

        #expect(
            VideoPublishAgeFormatter.label(for: video, relativeTo: now, locale: locale)
                == "an hour ago"
        )
    }

    @Test("Older approximate API label is preserved without renderer prefixes")
    func olderApproximationIsPreserved() {
        let label = VideoPublishAgeFormatter.label(
            publishedAt: now.addingTimeInterval(-45 * 24 * 60 * 60),
            publishedTimeText: "Streamed 2 months ago",
            relativeTo: now,
            locale: locale
        )
        #expect(label == "2 months ago")
    }

    @Test("Live and upcoming videos do not receive upload-age labels")
    func liveAndUpcomingAreExcluded() {
        let live = Video(id: "live", title: "Live", channelTitle: "Channel", publishedAt: now, isLive: true)
        let upcoming = Video(id: "upcoming", title: "Upcoming", channelTitle: "Channel", publishedAt: now, isUpcoming: true)

        #expect(VideoPublishAgeFormatter.label(for: live, relativeTo: now, locale: locale) == nil)
        #expect(VideoPublishAgeFormatter.label(for: upcoming, relativeTo: now, locale: locale) == nil)
    }

    private func label(secondsAgo: TimeInterval) -> String {
        VideoPublishAgeFormatter.label(
            publishedAt: now.addingTimeInterval(-secondsAgo),
            relativeTo: now,
            locale: locale
        )
    }

    private func expectedRelative(
        _ value: Int,
        component: Calendar.Component
    ) -> String {
        var components = DateComponents()
        components.setValue(-value, for: component)
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .numeric
        formatter.unitsStyle = .short
        return formatter.localizedString(from: components)
    }
}
