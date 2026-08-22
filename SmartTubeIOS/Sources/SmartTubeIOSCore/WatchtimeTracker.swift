import Foundation
import os

private let trackerLog = Logger(subsystem: appSubsystem, category: "WatchtimeTracker")

// MARK: - WatchtimeTracker
//
// Owns all watch-history state for a single video session:
// position saving (VideoStateStore), playback-started ping, and
// watchtime segment reporting (InnerTubeAPI).
//
// Mirrors Android's VideoStateController + WatchHistory reporting.
//
// Lifecycle per video:
//   transition(to:cpn:flushPosition:flushDuration:)
//     → called from load() to flush the previous session and begin a new one.
//       Returns a @Sendable async closure; fire it in a detached Task.
//
//   setTrackingURLs(_:)
//     → called once authenticated tracking URLs resolve in loadAsync.
//
//   playbackStarted()
//     → called when AVPlayer's rate first becomes positive; immediately records
//       the view instead of waiting for the player to close.
//
//   checkpoint(position:duration:)
//     → called from suspend(), stop(); saves progress and reports watchtime.

@MainActor
public final class WatchtimeTracker {

    // MARK: - Private state

    private let api: InnerTubeAPI

    private var videoId: String = ""
    private var cpn: String = ""
    private var trackingURLs: PlaybackTrackingURLs?
    /// Nil until playback actually starts (or a defensive first checkpoint).
    private var segmentStart: TimeInterval?

    // MARK: - Init

    public init(api: InnerTubeAPI) {
        self.api = api
    }

    // MARK: - Transition (load → new video)

    /// Atomically captures the current session for async flushing and resets state
    /// for the new video. Call from `load()`:
    ///
    /// ```swift
    /// let flush = tracker.transition(to: video.id, cpn: ..., flushPosition: pos, flushDuration: dur)
    /// Task { await flush() }
    /// ```
    ///
    /// The returned closure owns its own copy of the old session state, so calling
    /// `begin()` / `setTrackingURLs()` for the new video immediately after is safe.
    @discardableResult
    public func transition(
        to newVideoId: String,
        cpn newCPN: String,
        flushPosition: TimeInterval,
        flushDuration: TimeInterval
    ) -> @Sendable () async -> Void {
        // Capture old session synchronously.
        let oldVideoId    = videoId
        let oldCPN        = cpn
        let oldURLs       = trackingURLs
        let oldSegStart   = segmentStart
        let api           = self.api

        // Reset to new session synchronously — no race with the returned closure.
        videoId      = newVideoId
        cpn          = newCPN
        trackingURLs = nil
        segmentStart = nil

        trackerLog.notice("transition: \(oldVideoId, privacy: .private(mask: .hash)) → \(newVideoId, privacy: .private(mask: .hash))")

        return {
            guard !oldVideoId.isEmpty, flushDuration > 0 else { return }
            if oldSegStart == nil {
                // Playback started but checkpoint was never reached — fire ping now.
                await api.reportPlaybackStarted(videoId: oldVideoId, cpn: oldCPN, trackingURLs: oldURLs)
            }
            // Use 0 when no prior checkpoint set a segment start so that the reported
            // interval is [0, flushPosition] rather than [flushPosition, flushPosition].
            // YouTube ignores zero-length watchtime segments (st == et), which would
            // prevent cmt from being recorded and leave the watch-progress bar stale.
            let segStart = oldSegStart ?? 0
            trackerLog.notice("transition flush: videoId=\(oldVideoId, privacy: .public) st=\(Int(segStart))s et=\(Int(flushPosition))s")
            await VideoStateStore.shared.save(videoId: oldVideoId, position: flushPosition, duration: flushDuration)
            await api.reportWatchtime(videoId: oldVideoId, cpn: oldCPN, trackingURLs: oldURLs,
                                      segmentStart: segStart, segmentEnd: flushPosition)
        }
    }

    // MARK: - Tracking URLs

    /// Store authenticated tracking URLs once they resolve in `loadAsync`.
    /// Safe to call any time between `transition` and the first `checkpoint`.
    public func setTrackingURLs(_ urls: PlaybackTrackingURLs?) {
        trackingURLs = urls
        trackerLog.notice("setTrackingURLs: \(urls != nil ? "account-bound" : "nil", privacy: .public)")
    }

    // MARK: - Playback start

    /// Records the start as soon as AVPlayer begins advancing. This used to wait
    /// until pause/stop, which made very recent videos absent from server History.
    /// Setting `segmentStart` before awaiting makes repeated rate changes idempotent.
    public func playbackStarted() async {
        guard !videoId.isEmpty, segmentStart == nil else { return }

        let vid = videoId
        let localCPN = cpn
        let localURLs = trackingURLs
        segmentStart = 0
        trackerLog.notice("playbackStarted: videoId=\(vid, privacy: .public) — firing immediately")
        await api.reportPlaybackStarted(videoId: vid, cpn: localCPN, trackingURLs: localURLs)
    }

    // MARK: - Checkpoint (suspend / stop)

    /// Records the current watch position and reports the watched interval.
    ///
    /// If no positive player rate was observed, the first checkpoint defensively
    /// sends `reportPlaybackStarted`. Subsequent calls save the position and report
    /// the interval [segmentStart, position].
    public func checkpoint(position: TimeInterval, duration: TimeInterval) async {
        guard !videoId.isEmpty, duration > 0 else { return }

        let vid       = videoId
        let localCPN  = cpn
        let localURLs = trackingURLs

        if segmentStart == nil {
            // Use 0 as the segment start so the reported interval is [0, position]
            // rather than [position, position]. YouTube ignores zero-length watchtime
            // segments (st == et), which would prevent cmt from being recorded and
            // leave the watch-progress bar stuck at a stale value.
            trackerLog.notice("checkpoint (first): videoId=\(vid, privacy: .public) pos=\(Int(position))s — firing playbackStarted")
            await playbackStarted()
        }

        let segStart = segmentStart ?? 0
        trackerLog.notice("checkpoint: videoId=\(vid, privacy: .public) st=\(Int(segStart))s et=\(Int(position))s dur=\(Int(duration))s")
        await VideoStateStore.shared.save(videoId: vid, position: position, duration: duration)
        await api.reportWatchtime(videoId: vid, cpn: localCPN, trackingURLs: localURLs,
                                   segmentStart: segStart, segmentEnd: position)
        segmentStart = position
    }
}
