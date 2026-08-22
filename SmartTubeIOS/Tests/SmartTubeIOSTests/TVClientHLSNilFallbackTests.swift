import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - TVClientHLSNilFallbackTests (NW-3-FIX)
//
// Verifies the model-level condition used by the authenticated-TV fallback in
// PlaybackViewModel+Loading.swift.
//
// When the TV authenticated client returns a `PlayerInfo` with:
//   - hlsURL = nil
//   - bestAdaptiveVideoURL = nil  (no video-only adaptive stream)
//   - bestAdaptiveAudioURL = nil  (no audio-only adaptive stream)
//
// …a direct muxed MP4 must be retained instead of being discarded solely because
// the response has no HLS or separate adaptive pair.
//
// The fix lives in PlaybackViewModel+Loading.swift:
//   if info.hlsURL == nil,
//      info.bestMuxedDownloadURL == nil,
//      info.bestAdaptiveVideoURL == nil || info.bestAdaptiveAudioURL == nil { … }
//
// These tests validate the three `PlayerInfo` computed properties that feed that
// condition, for the two key TV-client response shapes.

@Suite("NW-3-FIX: TV client HLS-nil fallback condition")
struct TVClientHLSNilFallbackTests {

    // MARK: - Helpers

    private func makeVideo() -> Video {
        Video(id: "test-video", title: "Test", channelTitle: "Channel")
    }

    /// A `PlayerInfo` shaped like the current authenticated TV response:
    /// direct muxed MP4 (itag=18), no HLS, no adaptive streams.
    private func makeMuxedOnlyPlayerInfo() -> PlayerInfo {
        let muxedFormat = VideoFormat(
            label: "360p",
            width: 640, height: 360, fps: 30,
            mimeType: "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"",
            url: URL(string: "https://r1---sn-foo.googlevideo.com/videoplayback?itag=18&c=TVHTML5"),
            bitrate: 500_000
        )
        return PlayerInfo(
            video: makeVideo(),
            formats: [muxedFormat],
            hlsURL: nil,
            dashURL: nil,
            captionTracks: [],
            trackingURLs: nil,
            endCards: []
        )
    }

    /// A `PlayerInfo` with a valid HLS URL (normal TV or iOS client response).
    private func makeHLSPlayerInfo() -> PlayerInfo {
        PlayerInfo(
            video: makeVideo(),
            formats: [],
            hlsURL: URL(string: "https://manifest.googlevideo.com/api/manifest/hls_playlist"),
            dashURL: nil,
            captionTracks: [],
            trackingURLs: nil,
            endCards: []
        )
    }

    /// A `PlayerInfo` with adaptive video + audio streams but no HLS (Android-client shape).
    private func makeAdaptivePlayerInfo() -> PlayerInfo {
        let videoFormat = VideoFormat(
            label: "1080p",
            width: 1920, height: 1080, fps: 30,
            mimeType: "video/mp4; codecs=\"avc1.640028\"",
            url: URL(string: "https://r1---sn-foo.googlevideo.com/videoplayback?itag=137"),
            bitrate: 3_000_000
        )
        let audioFormat = VideoFormat(
            label: "Audio",
            width: 0, height: 0, fps: 0,
            mimeType: "audio/mp4; codecs=\"mp4a.40.2\"",
            url: URL(string: "https://r1---sn-foo.googlevideo.com/videoplayback?itag=140"),
            bitrate: 128_000
        )
        return PlayerInfo(
            video: makeVideo(),
            formats: [videoFormat, audioFormat],
            hlsURL: nil,
            dashURL: nil,
            captionTracks: [],
            trackingURLs: nil,
            endCards: []
        )
    }

    // MARK: - Muxed-only (TV client DRM response)

    @Test("Muxed-only TV response: hlsURL is nil")
    func muxedOnlyHlsURLIsNil() {
        let info = makeMuxedOnlyPlayerInfo()
        #expect(info.hlsURL == nil)
    }

    @Test("Muxed-only TV response: bestAdaptiveVideoURL is nil (muxed codec string excluded)")
    func muxedOnlyAdaptiveVideoURLIsNil() {
        let info = makeMuxedOnlyPlayerInfo()
        // Muxed formats have two codecs separated by ", " — the filter in
        // bestAdaptiveVideoURL requires !mimeType.contains(", ") so it is excluded.
        #expect(info.bestAdaptiveVideoURL == nil)
    }

    @Test("Muxed-only TV response: bestAdaptiveAudioURL is nil")
    func muxedOnlyAdaptiveAudioURLIsNil() {
        let info = makeMuxedOnlyPlayerInfo()
        #expect(info.bestAdaptiveAudioURL == nil)
    }

    @Test("Muxed-only TV response remains a playable fallback candidate")
    func muxedOnlyDoesNotFallThroughToAndroid() {
        let info = makeMuxedOnlyPlayerInfo()
        let shouldFallback = info.hlsURL == nil &&
            info.bestMuxedDownloadURL == nil &&
            (info.bestAdaptiveVideoURL == nil || info.bestAdaptiveAudioURL == nil)
        #expect(!shouldFallback,
                "Direct TVHTML5 muxed MP4 must remain eligible for playback")
    }

    // MARK: - HLS response (no fallback expected)

    @Test("HLS response: fallback condition does NOT fire")
    func hlsResponseFallbackConditionDoesNotFire() {
        let info = makeHLSPlayerInfo()
        let shouldFallback = info.hlsURL == nil &&
            (info.bestAdaptiveVideoURL == nil || info.bestAdaptiveAudioURL == nil)
        #expect(!shouldFallback,
                "NW-3-FIX condition must not fire when hlsURL is present")
    }

    // MARK: - Adaptive streams response (no fallback expected)

    @Test("Adaptive-only response: bestAdaptiveVideoURL is non-nil")
    func adaptiveResponseHasVideoURL() {
        let info = makeAdaptivePlayerInfo()
        #expect(info.bestAdaptiveVideoURL != nil)
    }

    @Test("Adaptive-only response: bestAdaptiveAudioURL is non-nil")
    func adaptiveResponseHasAudioURL() {
        let info = makeAdaptivePlayerInfo()
        #expect(info.bestAdaptiveAudioURL != nil)
    }

    @Test("Adaptive-only response: fallback condition does NOT fire")
    func adaptiveResponseFallbackConditionDoesNotFire() {
        let info = makeAdaptivePlayerInfo()
        // hlsURL is nil BUT both adaptive streams are present — only one nil needed
        // for the condition to fire, so we also need hlsURL == nil to be true here.
        // The full condition is: hlsURL==nil AND (adaptiveVideo==nil OR adaptiveAudio==nil)
        // With adaptive streams present both are non-nil, so the AND's RHS is false.
        let shouldFallback = info.hlsURL == nil &&
            (info.bestAdaptiveVideoURL == nil || info.bestAdaptiveAudioURL == nil)
        #expect(!shouldFallback,
                "NW-3-FIX condition must not fire when adaptive streams are available")
    }

    // MARK: - Direct-stream fallback policy

    private func hasNoDirectPlaybackCandidate(_ info: PlayerInfo) -> Bool {
        info.hlsURL == nil &&
        info.bestMuxedDownloadURL == nil &&
        info.bestAdaptiveVideoURL == nil &&
        info.bestAdaptiveAudioURL == nil
    }

    @Test("Muxed-only response is not treated as missing direct playback")
    func muxedOnlyIsDirectPlaybackCandidate() {
        let info = makeMuxedOnlyPlayerInfo()
        #expect(!hasNoDirectPlaybackCandidate(info))
    }

    @Test("HLS response is a direct playback candidate")
    func hlsIsDirectPlaybackCandidate() {
        let info = makeHLSPlayerInfo()
        #expect(!hasNoDirectPlaybackCandidate(info))
    }

    @Test("Adaptive response is a direct playback candidate")
    func adaptiveIsDirectPlaybackCandidate() {
        let info = makeAdaptivePlayerInfo()
        #expect(!hasNoDirectPlaybackCandidate(info))
    }

    @Test("Muxed-only response exposes its direct preferredStreamURL")
    func androidMuxedOnlyHasPreferredStreamURL() {
        let info = makeMuxedOnlyPlayerInfo()
        #expect(info.preferredStreamURL != nil,
                "muxed-only response must expose its direct MP4 URL")
        #expect(!hasNoDirectPlaybackCandidate(info))
    }

    // MARK: - Fix #122: Android no-HLS with adaptive streams → use adaptive composition

    /// The new guard in retryWithFallbackPlayer (Fix #122):
    ///   if fallbackInfo.hlsURL == nil,
    ///      fallbackInfo.bestAdaptiveVideoURL != nil,
    ///      fallbackInfo.bestAdaptiveAudioURL != nil { → use adaptive composition }
    private func shouldDelegateToAdaptiveComposition(_ info: PlayerInfo) -> Bool {
        info.hlsURL == nil &&
        info.bestAdaptiveVideoURL != nil &&
        info.bestAdaptiveAudioURL != nil
    }

    @Test("Fix #122: Android adaptive-only response triggers adaptive composition delegation")
    func fix122AdaptiveOnlyTriggersDelegation() {
        // Adaptive video + audio, no HLS — the new guard must route to adaptive composition
        // instead of using preferredStreamURL (muxed URL) which would fail with -11828.
        let info = makeAdaptivePlayerInfo()
        #expect(shouldDelegateToAdaptiveComposition(info),
                "Fix #122: guard must fire for no-HLS + adaptive Android response")
    }

    @Test("Fix #122: adaptive response preferredStreamURL returns nil (no muxed URL to fall back to)")
    func fix122AdaptiveOnlyPreferredStreamURLIsNil() {
        // When the Android response has only adaptive streams (no muxed MP4 with ", "),
        // preferredStreamURL returns nil — confirming the muxed path cannot be used.
        let info = makeAdaptivePlayerInfo()
        #expect(info.preferredStreamURL == nil,
                "Fix #122: adaptive-only response has no muxed URL — must use adaptive composition")
    }

    @Test("Fix #122: HLS Android response does NOT trigger adaptive composition delegation")
    func fix122HLSResponseDoesNotTriggerDelegation() {
        let info = makeHLSPlayerInfo()
        #expect(!shouldDelegateToAdaptiveComposition(info),
                "Fix #122: delegation must not fire when Android returns HLS")
    }

    @Test("Fix #122: muxed-only response does not trigger adaptive composition")
    func fix122MuxedOnlyDoesNotTriggerDelegation() {
        // Muxed-only has no adaptive streams, so the Fix #122 condition is false.
        let info = makeMuxedOnlyPlayerInfo()
        #expect(!shouldDelegateToAdaptiveComposition(info),
                "Muxed-only playback must use the direct MP4 path")
    }
}
