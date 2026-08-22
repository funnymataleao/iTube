import Foundation
import os
import SmartTubeIOSCore

private let playerLog = CrashlyticsLogger(category: "Player")

// MARK: - Auth Token

extension PlaybackViewModel {

    /// Updates the local auth flag used for LOGIN_REQUIRED retry logic.
    /// The shared InnerTubeAPI instance already carries the updated token.
    public func updateAuthToken(_ token: String?) {
        let effectiveToken = token.flatMap { $0.isEmpty ? nil : $0 }
        authUpdateRevision &+= 1
        let revision = authUpdateRevision
        let wasAuthenticated = hasAuthToken
        hasAuthToken = effectiveToken != nil
        currentAuthToken = effectiveToken
        if effectiveToken == nil {
            // SponsorBlock is an authenticated feature. Keep the persisted user
            // preference intact, but remove every active marker/toast/skip as soon
            // as playback enters guest mode.
            sponsorBlockManager.reset()
        }
        // Propagate the token to the PlaybackViewModel's own API instance so that
        // WatchtimeTracker sends authenticated watch-time pings (fixes watch history
        // not being recorded for signed-in users — GitHub issue #51).
        Task { [weak self] in
            guard let self else { return }
            await self.api.setAuthToken(effectiveToken)
            guard self.authUpdateRevision == revision else {
                let latest = self.currentAuthToken
                await self.api.setAuthToken(latest)
                await VideoPreloadCache.shared.setAuthToken(latest)
                return
            }
            // Keep the cache's InnerTubeAPI instance in sync so prefetch requests
            // can make authenticated calls (e.g. fetchAuthenticatedTrackingURLs).
            await VideoPreloadCache.shared.setAuthToken(effectiveToken)
            guard self.authUpdateRevision == revision else {
                let latest = self.currentAuthToken
                await self.api.setAuthToken(latest)
                await VideoPreloadCache.shared.setAuthToken(latest)
                return
            }
        }
        if wasAuthenticated, effectiveToken == nil {
            // Signed out: evict account-bound cache data
            Task { await VideoPreloadCache.shared.evictAuthSensitiveData() }
        } else if wasAuthenticated, effectiveToken != nil {
            // Token refreshed: tracking URLs bound to the old token are stale.
            // BUG-016 fix: also clear WatchtimeTracker so any in-flight checkpoint between
            // the token refresh and the next video load uses nil URLs rather than stale ones.
            tracker.setTrackingURLs(nil)
            Task { await VideoPreloadCache.shared.evictTrackingURLs() }
        }
    }

    /// Propagates the YouTube.com SAPISID cookie to the PlaybackViewModel's own
    /// InnerTubeAPI instance so WEB_CREATOR requests use SAPISIDHASH auth.
    public func updateSAPISID(_ sapisid: String?) {
        Task { await api.setSAPISID(sapisid) }
        Task { await VideoPreloadCache.shared.setSAPISID(sapisid) }
    }
}
