import Foundation

// MARK: - Subscription topics

/// A stable, product-facing topic taxonomy for the tvOS subscriptions feed.
///
/// YouTube's upload categories are intentionally broad. The classifier below
/// preserves those official categories while promoting a few useful living-room
/// topics (DIY electronics, business/finance, podcasts, and science) using the
/// public snippet title/tags returned by the YouTube Data API.
public enum SubscriptionTopic: String, CaseIterable, Codable, Hashable, Sendable {
    case all
    case diyElectronics
    case technology
    case gaming
    case newsPolitics
    case science
    case education
    case businessFinance
    case autosVehicles
    case music
    case filmAnimation
    case entertainment
    case comedy
    case travelEvents
    case foodLifestyle
    case sports
    case petsAnimals
    case podcastsInterviews
    case peopleBlogs
    case nonprofitsActivism
    case other

    public static var classifiedCases: [SubscriptionTopic] {
        // `.other` remains an internal classifier fallback. Exposing it as a
        // destination produces a huge miscellaneous bucket and starves every
        // useful category, so it must never become a user-facing tab.
        allCases.filter { $0 != .all && $0 != .other }
    }
}

/// The small portion of `videos.list(part=snippet)` needed for topic grouping.
public struct VideoTopicMetadata: Codable, Equatable, Sendable {
    public let videoID: String
    public let categoryID: String?
    public let tags: [String]
    /// Exact public publish timestamp from `videos.list(part=snippet)`.
    /// Unlike InnerTube's relative label, this is precise enough for minute/hour UI.
    public let publishedAt: Date?

    public init(
        videoID: String,
        categoryID: String?,
        tags: [String],
        publishedAt: Date? = nil
    ) {
        self.videoID = videoID
        self.categoryID = categoryID
        self.tags = tags
        self.publishedAt = publishedAt
    }
}

// MARK: - Classifier

public enum SubscriptionTopicClassifier {
    /// Produces exactly one primary topic for a video so the filtered feed never
    /// duplicates a card. Custom keyword groups take precedence over YouTube's
    /// broader uploader-selected category.
    public static func topic(
        for video: Video,
        metadata: VideoTopicMetadata?
    ) -> SubscriptionTopic {
        let searchableText = normalizedSearchText(video: video, metadata: metadata)

        if containsAny(searchableText, keywords: diyElectronicsKeywords) {
            return .diyElectronics
        }
        if containsAny(searchableText, keywords: businessFinanceKeywords) {
            return .businessFinance
        }
        if containsAny(searchableText, keywords: podcastInterviewKeywords) {
            return .podcastsInterviews
        }

        switch metadata?.categoryID {
        case "1", "30", "31", "32", "33", "35", "36", "37", "38", "39", "40", "41", "42", "43", "44":
            return .filmAnimation
        case "2":
            return .autosVehicles
        case "10":
            return .music
        case "15":
            return .petsAnimals
        case "17":
            return .sports
        case "19":
            return .travelEvents
        case "20":
            return .gaming
        case "22":
            return .peopleBlogs
        case "23":
            return .comedy
        case "24":
            return .entertainment
        case "25":
            return .newsPolitics
        case "26":
            return .foodLifestyle
        case "27":
            return .education
        case "28":
            return containsAny(searchableText, keywords: scienceKeywords) ? .science : .technology
        case "29":
            return .nonprofitsActivism
        default:
            return fallbackTopic(from: searchableText)
        }
    }

    private static func fallbackTopic(from text: String) -> SubscriptionTopic {
        if containsAny(text, keywords: scienceKeywords) { return .science }
        if containsAny(text, keywords: gamingKeywords) { return .gaming }
        if containsAny(text, keywords: politicsKeywords) { return .newsPolitics }
        if containsAny(text, keywords: technologyKeywords) { return .technology }
        if containsAny(text, keywords: autosVehiclesKeywords) { return .autosVehicles }
        if containsAny(text, keywords: educationKeywords) { return .education }
        if containsAny(text, keywords: musicKeywords) { return .music }
        if containsAny(text, keywords: filmAnimationKeywords) { return .filmAnimation }
        if containsAny(text, keywords: foodLifestyleKeywords) { return .foodLifestyle }
        if containsAny(text, keywords: sportsKeywords) { return .sports }
        if containsAny(text, keywords: petsAnimalsKeywords) { return .petsAnimals }
        if containsAny(text, keywords: comedyKeywords) { return .comedy }
        if containsAny(text, keywords: travelEventsKeywords) { return .travelEvents }
        if containsAny(text, keywords: entertainmentKeywords) { return .entertainment }
        if containsAny(text, keywords: peopleBlogsKeywords) { return .peopleBlogs }
        if containsAny(text, keywords: nonprofitsActivismKeywords) { return .nonprofitsActivism }
        return .other
    }

    private static func normalizedSearchText(
        video: Video,
        metadata: VideoTopicMetadata?
    ) -> String {
        ([video.title, video.channelTitle] + (metadata?.tags ?? []))
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func containsAny(_ text: String, keywords: [String]) -> Bool {
        keywords.contains(where: text.contains)
    }

    private static let diyElectronicsKeywords = [
        "arduino", "esp32", "esp8266", "raspberry pi", "microcontroller", "micro-controller",
        "pcb", "printed circuit", "solder", "soldering", "circuit board", "electronics project",
        "electronic project", "fpga", "stm32", "zigbee", "home assistant", "smart home diy",
        "ардуино", "электроник", "микроконтрол", "печатн плат", "паяль", "пайк", "электрическ схем",
        "eletronica", "eletronica", "microcontrolador", "placa de circuito", "soldagem",
    ]

    private static let businessFinanceKeywords = [
        "finance", "financial", "investing", "investment", "stock market", "stocks", "portfolio",
        "business", "startup", "entrepreneur", "economy", "economic", "crypto", "bitcoin",
        "финанс", "инвест", "фондов", "акци", "бизнес", "стартап", "эконом", "крипт",
        "financas", "investimento", "mercado financeiro", "negocios", "economia",
    ]

    private static let podcastInterviewKeywords = [
        "podcast", "interview", "conversation with", "in conversation", "long-form", "long form",
        "подкаст", "интервью", "разговор с", "беседа с", "entrevista", "conversa com",
    ]

    private static let scienceKeywords = [
        "science", "scientific", "physics", "astronomy", "space", "cosmos", "chemistry", "biology",
        "research", "quantum", "neuroscience", "наук", "физик", "астроном", "космос", "хими", "биолог",
        "ciencia", "fisica", "astronomia", "espaco", "quimica", "biologia",
    ]

    private static let gamingKeywords = [
        "gaming", "gameplay", "video game", "xbox", "playstation", "nintendo", "steam deck",
        "steam", "stalker", "gta", "minecraft", "fortnite", "counter-strike", "cyberpunk",
        "игр", "геймплей", "видеоигр", "сталкер", "jogos", "gameplay",
    ]

    private static let politicsKeywords = [
        "politics", "political", "election", "parliament", "government", "geopolitics",
        "putin", "ukraine", "russia", "war ", "nato", "kremlin", "trump", "world news",
        "политик", "выбор", "парламент", "правительств", "геополит", "путин", "украин",
        "росси", "войн", "новост", "кремл", "нато", "трамп", "politica", "eleicao", "governo",
    ]

    private static let technologyKeywords = [
        "technology", "tech", "software", "hardware", "computer", "apple", "android", "linux", "ai ",
        "iphone", "ipad", "macbook", "smartphone", "laptop", "headphone", "earbud", "gadget",
        "gpu", "cpu", "camera review", "технолог", "софт", "железо", "компьютер", "техник",
        "смартфон", "телефон", "наушник", "гаджет", "видеокарт", "tecnologia", "software", "hardware",
    ]

    private static let educationKeywords = [
        "tutorial", "explained", "course", "lesson", "lecture", "how to", "learn",
        "урок", "обуч", "курс", "лекци", "как сделать", "tutorial", "curso", "aula", "aprender",
    ]

    private static let autosVehiclesKeywords = [
        "automotive", "vehicle", "electric car", "electric bike", "unicycle", "motorcycle",
        "scooter", "tesla", "автомоб", "машин", "транспорт", "электромоб", "велосипед",
        "мотоцикл", "самокат", "моноколес", "veiculo", "carro", "moto",
    ]

    private static let musicKeywords = [
        "music", "song", "album", "concert", "singer", "guitar", "piano", "drums",
        "музык", "песн", "альбом", "концерт", "гитар", "пианино", "барабан",
        "musica", "cancao", "concerto",
    ]

    private static let filmAnimationKeywords = [
        "movie", "film", "cinema", "animation", "animated", "cartoon", "trailer",
        "кино", "фильм", "мульт", "анимац", "трейлер", "filme", "cinema", "animacao",
    ]

    private static let foodLifestyleKeywords = [
        "health", "medical", "doctor", "nutrition", "diet", "fitness", "recipe", "cooking", "food",
        "здоров", "медицин", "доктор", "врач", "питан", "диет", "фитнес", "рецепт", "кухн",
        "saude", "medico", "nutricao", "receita", "comida",
    ]

    private static let sportsKeywords = [
        "football", "soccer", "basketball", "hockey", "tennis", "formula 1", "boxing", "ufc",
        "футбол", "баскетбол", "хоккей", "теннис", "формула 1", "бокс", "esporte", "futebol",
    ]

    private static let petsAnimalsKeywords = [
        "animal", "wildlife", "pet ", "pets", "dog ", "dogs", "cat ", "cats",
        "животн", "питом", "собак", "кошк", "natureza", "animais",
    ]

    private static let comedyKeywords = [
        "comedy", "comedian", "stand-up", "standup", "funny", "humor",
        "комед", "стендап", "юмор", "смешн", "comedia", "humor",
    ]

    private static let travelEventsKeywords = [
        "travel", "trip ", "road trip", "tour ", "hotel", "flight", "destination",
        "путешеств", "поездк", "туризм", "отел", "перелет", "viagem", "turismo",
    ]

    private static let entertainmentKeywords = [
        "entertainment", "tv show", "reality show", "talk show", "celebrity", "reaction",
        "behind the scenes", "award show", "развлеч", "телешоу", "знаменит", "реакци",
        "bastidores", "entretenimento",
    ]

    private static let peopleBlogsKeywords = [
        "vlog", "video blog", "personal story", "day in my life", "life update",
        "влог", "видеоблог", "личная история", "день из жизни", "blog pessoal",
    ]

    private static let nonprofitsActivismKeywords = [
        "nonprofit", "non-profit", "charity", "activism", "human rights", "ngo ",
        "благотвор", "активизм", "правозащит", "direitos humanos", "caridade",
    ]
}

// MARK: - Persistent metadata cache

public actor SubscriptionTopicMetadataCache {
    public static let shared = SubscriptionTopicMetadataCache()

    private struct CacheEntry: Codable, Sendable {
        let metadata: VideoTopicMetadata
        let fetchedAt: Date
    }

    // v2 adds exact `publishedAt`. Keeping it separate prevents a 30-day-old
    // v1 entry from being mistaken for complete timestamp metadata.
    private static let defaultsKey = "st_subscription_topic_metadata_v2"
    private static let timeToLive: TimeInterval = 30 * 24 * 60 * 60
    private static let maximumEntryCount = 800

    private let defaults: UserDefaults
    private var entries: [String: CacheEntry]

    private init() {
        defaults = .standard
        entries = Self.load(from: .standard)
    }

    init(suiteName: String) {
        let isolatedDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults = isolatedDefaults
        entries = Self.load(from: isolatedDefaults)
    }

    #if DEBUG
    /// Isolated storage used by the tvOS Debug self-test. This initializer is
    /// not present in release builds and cannot affect the production cache.
    public init(debugSuiteName: String) {
        let isolatedDefaults = UserDefaults(suiteName: debugSuiteName) ?? .standard
        defaults = isolatedDefaults
        entries = Self.load(from: isolatedDefaults)
    }
    #endif

    public func metadata(
        for videoIDs: [String],
        now: Date = Date()
    ) -> [String: VideoTopicMetadata] {
        let requested = Set(videoIDs)
        var result: [String: VideoTopicMetadata] = [:]
        var expiredVideoIDs: [String] = []

        for (videoID, entry) in entries where requested.contains(videoID) {
            guard now.timeIntervalSince(entry.fetchedAt) <= Self.timeToLive else {
                expiredVideoIDs.append(videoID)
                continue
            }
            result[videoID] = entry.metadata
        }

        if !expiredVideoIDs.isEmpty {
            for videoID in expiredVideoIDs {
                entries.removeValue(forKey: videoID)
            }
            persist()
        }
        return result
    }

    public func store(
        _ metadataByVideoID: [String: VideoTopicMetadata],
        now: Date = Date()
    ) {
        for (videoID, metadata) in metadataByVideoID {
            entries[videoID] = CacheEntry(metadata: metadata, fetchedAt: now)
        }

        if entries.count > Self.maximumEntryCount {
            let retainedIDs = entries
                .sorted { $0.value.fetchedAt > $1.value.fetchedAt }
                .prefix(Self.maximumEntryCount)
                .map(\.key)
            let retainedIDSet = Set(retainedIDs)
            entries = entries.filter { retainedIDSet.contains($0.key) }
        }
        persist()
    }

    public func clear() {
        entries.removeAll()
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> [String: CacheEntry] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
