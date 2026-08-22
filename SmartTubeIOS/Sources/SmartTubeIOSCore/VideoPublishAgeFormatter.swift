import Foundation

/// Produces the compact, localized publish-age label used by every video card.
///
/// YouTube sometimes supplies only an approximate `publishedAt`, so older videos
/// keep the service-provided relative label when one is available. An exact API
/// timestamp always wins; a bare `Today` is omitted instead of being turned into
/// a fabricated minute value while exact enrichment is unavailable.
public enum VideoPublishAgeFormatter {
    public static func label(
        for video: Video,
        relativeTo referenceDate: Date = .now,
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        guard !video.isLive, !video.isUpcoming else { return nil }

        if let exactPublishedAt = video.exactPublishedAt {
            return label(
                publishedAt: exactPublishedAt,
                relativeTo: referenceDate,
                locale: locale
            )
        }

        let fallback = cleanedFallback(video.publishedTimeText)
        if let fallback, isCoarseTodayLabel(fallback, locale: locale) {
            // A localized "Today" section contains no hour/minute information.
            // Exact metadata normally replaces it; if enrichment fails, hiding
            // the age is more honest than inventing 1m.
            return nil
        }

        if let fallback {
            switch fallback.lowercased(with: locale) {
            case "just now", "moments ago":
                return localized(value: 1, component: .minute, locale: locale)
            case "yesterday":
                return localized(value: 1, component: .day, locale: locale)
            default:
                break
            }
        }

        if let publishedAt = video.publishedAt {
            return label(
                publishedAt: publishedAt,
                publishedTimeText: video.publishedTimeText,
                relativeTo: referenceDate,
                locale: locale
            )
        }

        return fallback
    }

    public static func label(
        publishedAt: Date,
        publishedTimeText: String? = nil,
        relativeTo referenceDate: Date = .now,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let elapsed = max(0, referenceDate.timeIntervalSince(publishedAt))

        if elapsed < 60 {
            return localized(value: 1, component: .minute, locale: locale)
        }
        if elapsed < 3_600 {
            return localized(
                value: max(1, Int(elapsed / 60)),
                component: .minute,
                locale: locale
            )
        }
        if elapsed < 86_400 {
            return localized(
                value: max(1, Int(elapsed / 3_600)),
                component: .hour,
                locale: locale
            )
        }
        if elapsed < 7 * 86_400 {
            return localized(
                value: max(1, Int(elapsed / 86_400)),
                component: .day,
                locale: locale
            )
        }

        // The API label is more honest for older entries whose `publishedAt`
        // was reconstructed from coarse text such as "2 months ago".
        if let fallback = cleanedFallback(publishedTimeText) {
            return fallback
        }

        if elapsed < 30 * 86_400 {
            return localized(
                value: max(1, Int(elapsed / (7 * 86_400))),
                component: .weekOfMonth,
                locale: locale
            )
        }
        if elapsed < 365 * 86_400 {
            return localized(
                value: max(1, Int(elapsed / (30 * 86_400))),
                component: .month,
                locale: locale
            )
        }
        return localized(
            value: max(1, Int(elapsed / (365 * 86_400))),
            component: .year,
            locale: locale
        )
    }

    private static func cleanedFallback(_ publishedTimeText: String?) -> String? {
        guard let raw = publishedTimeText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let cleaned = raw.replacingOccurrences(
            of: #"^(Streamed|Premiered|Started)\s+"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func isCoarseTodayLabel(_ text: String, locale: Locale) -> Bool {
        let normalizedText = normalizedRelativeLabel(text, locale: locale)
        guard normalizedText != "today" else { return true }

        var today = DateComponents()
        today.day = 0
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return normalizedText == normalizedRelativeLabel(
            formatter.localizedString(from: today),
            locale: locale
        )
    }

    private static func normalizedRelativeLabel(_ text: String, locale: Locale) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }

    private static func localized(
        value: Int,
        component: Calendar.Component,
        locale: Locale
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
