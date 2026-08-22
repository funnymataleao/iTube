import AVFoundation
import os
import SmartTubeIOSCore

// MARK: - SponsorBlock (thin wrapper — logic lives in SponsorBlockSkipManager)

extension PlaybackViewModel {

    @discardableResult
    public func checkSponsorSkip(at time: TimeInterval) -> Bool {
        guard hasAuthToken else {
            currentToastSegment = nil
            return false
        }
        return sponsorBlockManager.checkSponsorSkip(at: time)
    }

    public func skipToastSegment() {
        guard hasAuthToken else {
            currentToastSegment = nil
            return
        }
        sponsorBlockManager.skipToastSegment()
    }
}
