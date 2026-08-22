import SwiftUI
import SmartTubeIOSCore

// tvOS state used by the native AVKit player menus.
#if os(tvOS)

extension PlayerView {
    enum MoreMenuRow: Hashable {
        case speed, quality, like, dislike, sleepTimer, audioOnly, queueShuffle, captions,
             audioTrack, description, comments, statsForNerds, cancel
    }
}

#endif
