import Testing
@testable import SmartTubeIOSCore

@Suite("Subscription Topic Classifier")
struct SubscriptionTopicClassifierTests {
    @Test("DIY electronics overrides YouTube's broad technology category")
    func diyElectronicsOverride() {
        let video = Video(
            id: "arduino",
            title: "Build an Arduino weather station",
            channelTitle: "Workshop"
        )
        let metadata = VideoTopicMetadata(
            videoID: video.id,
            categoryID: "28",
            tags: ["soldering", "PCB"]
        )

        #expect(SubscriptionTopicClassifier.topic(for: video, metadata: metadata) == .diyElectronics)
    }

    @Test("Official gaming category maps without title heuristics")
    func officialGamingCategory() {
        let video = Video(id: "game", title: "Weekly roundup", channelTitle: "Channel")
        let metadata = VideoTopicMetadata(videoID: video.id, categoryID: "20", tags: [])

        #expect(SubscriptionTopicClassifier.topic(for: video, metadata: metadata) == .gaming)
    }

    @Test("Science tags split science from general technology")
    func scienceTechnologySplit() {
        let scienceVideo = Video(id: "science", title: "A new discovery", channelTitle: "Lab")
        let scienceMetadata = VideoTopicMetadata(
            videoID: scienceVideo.id,
            categoryID: "28",
            tags: ["physics", "quantum"]
        )
        let technologyVideo = Video(id: "tech", title: "New laptop review", channelTitle: "Devices")
        let technologyMetadata = VideoTopicMetadata(
            videoID: technologyVideo.id,
            categoryID: "28",
            tags: ["hardware"]
        )

        #expect(SubscriptionTopicClassifier.topic(for: scienceVideo, metadata: scienceMetadata) == .science)
        #expect(SubscriptionTopicClassifier.topic(for: technologyVideo, metadata: technologyMetadata) == .technology)
    }

    @Test("Fallback supports Russian topic text when metadata is unavailable")
    func russianFallback() {
        let video = Video(
            id: "politics",
            title: "Политика и выборы: итоги недели",
            channelTitle: "Новости"
        )

        #expect(SubscriptionTopicClassifier.topic(for: video, metadata: nil) == .newsPolitics)
    }

    @Test("Every video receives exactly one stable fallback topic")
    func unknownFallback() {
        let video = Video(id: "unknown", title: "A quiet afternoon", channelTitle: "Untitled")

        #expect(SubscriptionTopicClassifier.topic(for: video, metadata: nil) == .other)
    }
}
