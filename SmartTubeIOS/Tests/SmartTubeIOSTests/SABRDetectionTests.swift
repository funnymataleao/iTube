import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - SABRDetectionTests
//
// Regression tests: SABR is represented by serverAbrStreamingUrl, not by the
// `c=TVHTML5` query parameter on otherwise direct media URLs.

@Suite("SABR Detection")
struct SABRDetectionTests {

    // MARK: - Helpers

    private func makeFormat(mimeType: String, urlString: String?) -> VideoFormat {
        VideoFormat(
            label: "test",
            width: 1280, height: 720, fps: 30,
            mimeType: mimeType,
            url: urlString.flatMap { URL(string: $0) }
        )
    }

    private func makePlayerInfo(formats: [VideoFormat], hasServerAbrURL: Bool = false) -> PlayerInfo {
        PlayerInfo(
            video: Video(id: "test", title: "Test", channelTitle: "Channel"),
            formats: formats,
            hlsURL: nil,
            dashURL: nil,
            serverAbrURL: hasServerAbrURL
                ? URL(string: "https://rr1.googlevideo.com/videoplayback?sabr=1")
                : nil,
            captionTracks: [],
            trackingURLs: nil,
            endCards: []
        )
    }

    private let tvDirectURL = "https://rr1.googlevideo.com/videoplayback?itag=137&c=TVHTML5&source=yt"
    private let tvAudioURL = "https://rr1.googlevideo.com/videoplayback?itag=140&c=TVHTML5&source=yt"
    private let normalURL = "https://rr1.googlevideo.com/videoplayback?itag=137&c=IOS&source=yt"

    // MARK: - Tests

    @Test func containsSabrFormats_serverAbrWithoutDirectPair_returnsTrue() {
        let formats = [
            makeFormat(mimeType: "video/mp4; codecs=\"avc1.640028\"", urlString: nil),
        ]
        let info = makePlayerInfo(formats: formats, hasServerAbrURL: true)
        #expect(info.containsSabrFormats == true)
    }

    @Test func containsSabrFormats_tvHTML5DirectPair_returnsFalse() {
        let formats = [
            makeFormat(mimeType: "video/mp4; codecs=\"avc1.640028\"", urlString: tvDirectURL),
            makeFormat(mimeType: "audio/mp4; codecs=\"mp4a.40.2\"", urlString: tvAudioURL),
        ]
        let info = makePlayerInfo(formats: formats, hasServerAbrURL: true)
        #expect(info.containsSabrFormats == false)
    }

    @Test func containsSabrFormats_noAdaptiveFormats_returnsFalse() {
        let info = makePlayerInfo(formats: [])
        #expect(info.containsSabrFormats == false)
    }

    @Test func containsSabrFormats_muxedFormatOnly_returnsFalse() {
        // Muxed formats have ", " in mimeType — excluded from adaptive check
        let formats = [
            makeFormat(mimeType: "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"", urlString: tvDirectURL),
        ]
        let info = makePlayerInfo(formats: formats)
        #expect(info.containsSabrFormats == false)
    }

    @Test func containsSabrFormats_normalAdaptiveURL_returnsFalse() {
        let formats = [
            makeFormat(mimeType: "video/mp4; codecs=\"avc1.640028\"", urlString: normalURL),
        ]
        let info = makePlayerInfo(formats: formats)
        #expect(info.containsSabrFormats == false)
    }

    @Test func containsSabrFormats_nilURL_returnsFalse() {
        // Formats with no URL are excluded from adaptive check
        let formats = [
            makeFormat(mimeType: "video/mp4; codecs=\"avc1.640028\"", urlString: nil),
        ]
        let info = makePlayerInfo(formats: formats)
        #expect(info.containsSabrFormats == false)
    }
}
