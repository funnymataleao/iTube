#if os(tvOS)
import SwiftUI
import AVKit
@preconcurrency import SmartTubeIOSCore

private let tvSystemPlayerLog = CrashlyticsLogger(category: "Player")

@MainActor
struct TVSystemPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let videoGravity: AVLayerVideoGravity
    let video: Video
    let duration: TimeInterval
    let chapters: [Chapter]
    let availableFormats: [VideoFormat]
    let selectedFormatID: UUID?
    let availableCaptions: [CaptionTrack]
    let selectedCaptionID: String?
    let availableAudioTracks: [AudioTrack]
    let selectedAudioTrackID: String?
    let isSignedIn: Bool
    let likeStatus: LikeStatus
    let isInWatchLater: Bool
    let isUpdatingWatchLater: Bool
    let isSubscribed: Bool
    let hasPrevious: Bool
    let hasNext: Bool
    let captionText: String?
    let toastMessage: String?
    let onDismiss: @MainActor () -> Void
    let onPrevious: @MainActor () -> Void
    let onNext: @MainActor () -> Void
    let onLike: @MainActor () -> Void
    let onDislike: @MainActor () -> Void
    let onToggleWatchLater: @MainActor () -> Void
    let onToggleSubscription: @MainActor () -> Void
    let onSelectFormat: @MainActor (VideoFormat?) -> Void
    let onSelectCaption: @MainActor (CaptionTrack?) -> Void
    let onSelectAudioTrack: @MainActor (AudioTrack?) -> Void
    let onPrefetchQualities: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = videoGravity
        controller.showsPlaybackControls = true
        controller.playbackControlsIncludeTransportBar = true
        controller.playbackControlsIncludeInfoViews = true
        controller.transportBarIncludesTitleView = true
        controller.customInfoViewControllers = []
        controller.requiresLinearPlayback = false
        controller.skippingBehavior = .skipItem
        controller.isSkipBackwardEnabled = hasPrevious
        controller.isSkipForwardEnabled = hasNext
        controller.allowsPictureInPicturePlayback = true
        controller.appliesPreferredDisplayCriteriaAutomatically = true
        controller.speeds = []
        
        if #available(tvOS 16.0, *) {
            controller.contextualActions = []
        }
        
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .black
        controller.view.accessibilityIdentifier = "player.systemPlayer"

        context.coordinator.installCaptionLabel(in: controller)
        context.coordinator.installToastLabel(in: controller)
        context.coordinator.installRemoteTouchObserver(in: controller)
        context.coordinator.update(controller: controller, force: true)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.parent = self
        if controller.player !== player { controller.player = player }
        if controller.videoGravity != videoGravity { controller.videoGravity = videoGravity }
        context.coordinator.update(controller: controller, force: false)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: TVSystemPlayerView
        private var captionLabel: UILabel?
        private var toastLabel: UILabel?
        private var toastTask: Task<Void, Never>?
        private var metadataSignature: String = ""
        private var menuSignature: String = ""
        private var chapterArtwork: [URL: Data] = [:]
        private var artworkTask: Task<Void, Never>?
        private var didPrefetchQualities = false
        private weak var remoteTouchObserver: UITapGestureRecognizer?
        private weak var menuPressRecognizer: UITapGestureRecognizer?
        private weak var playerController: AVPlayerViewController?
        private var transportBarVisible = false
        private var revealScheduled = false
        private var dismissRequested = false

        init(parent: TVSystemPlayerView) {
            self.parent = parent
        }

        func update(controller: AVPlayerViewController, force: Bool) {
            controller.isSkipBackwardEnabled = parent.hasPrevious
            controller.isSkipForwardEnabled = parent.hasNext
            
            updateTransportItems(on: controller, force: force)
            updateMetadata(on: controller, force: force)
            updateCaptionLabel()
            updateToastLabel()

            if !didPrefetchQualities, !parent.availableFormats.isEmpty {
                didPrefetchQualities = true
                parent.onPrefetchQualities()
            }
        }

        func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
            dismissPlayerOnce()
            return false
        }

        func skipToNextItem(for playerViewController: AVPlayerViewController) {
            guard parent.hasNext else { return }
            parent.onNext()
        }

        func skipToPreviousItem(for playerViewController: AVPlayerViewController) {
            guard parent.hasPrevious else { return }
            parent.onPrevious()
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willTransitionToVisibilityOfTransportBar visible: Bool,
            with coordinator: any AVPlayerViewControllerAnimationCoordinator
        ) {
            transportBarVisible = visible
        }

        func installRemoteTouchObserver(in controller: AVPlayerViewController) {
            playerController = controller

            let menuPress = UITapGestureRecognizer(
                target: self,
                action: #selector(handleMenuPress(_:))
            )
            menuPress.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
            menuPress.cancelsTouchesInView = true
            menuPress.delaysTouchesBegan = false
            menuPress.delaysTouchesEnded = false
            menuPress.delegate = self
            controller.view.addGestureRecognizer(menuPress)
            menuPressRecognizer = menuPress

            let observer = UITapGestureRecognizer(
                target: self,
                action: #selector(ignoreObservedRemoteTouch(_:))
            )
            observer.cancelsTouchesInView = false
            observer.delaysTouchesBegan = false
            observer.delaysTouchesEnded = false
            observer.delegate = self
            controller.view.addGestureRecognizer(observer)
            remoteTouchObserver = observer

            // Keep the native AVKit controller in the responder chain. No SwiftUI
            // focusable/onMoveCommand layer is allowed above it.
            DispatchQueue.main.async { [weak controller] in
                guard let controller else { return }
                _ = controller.becomeFirstResponder()
                controller.setNeedsFocusUpdate()
                controller.updateFocusIfNeeded()
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard gestureRecognizer === remoteTouchObserver else { return true }
            // This delegate callback arrives on touch-down. Returning false makes
            // the observer completely passive, so AVKit still owns the same touch
            // for native scrubbing, focus navigation, and menu interaction.
            revealPlaybackControlsIfNeeded()
            return false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Let AVKit finish its own press bookkeeping, but our explicit Back
            // action still wins and dismisses the player immediately.
            gestureRecognizer === menuPressRecognizer || otherGestureRecognizer === menuPressRecognizer
        }

        @objc private func ignoreObservedRemoteTouch(_ recognizer: UITapGestureRecognizer) {}

        @objc private func handleMenuPress(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            dismissPlayerOnce()
        }

        private func dismissPlayerOnce() {
            guard !dismissRequested else { return }
            dismissRequested = true
            tvSystemPlayerLog.notice("[TVSystemPlayer] Back/Menu pressed — dismissing player immediately")
            parent.onDismiss()
        }

        private func revealPlaybackControlsIfNeeded() {
            guard !transportBarVisible, !revealScheduled, let controller = playerController else { return }
            revealScheduled = true
            tvSystemPlayerLog.notice("[TVSystemPlayer] clickpad touch-down — revealing native playback controls")

            // AVKit has no public `showControls()` command. Rebuilding its public
            // controls configuration on two run-loop turns reliably wakes the
            // transport UI while preserving the original touch for AVKit itself.
            controller.showsPlaybackControls = false
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let self, let controller else { return }
                controller.showsPlaybackControls = true
                controller.playbackControlsIncludeTransportBar = true
                controller.playbackControlsIncludeInfoViews = true
                controller.transportBarIncludesTitleView = true
                controller.customInfoViewControllers = []
                controller.setNeedsFocusUpdate()
                controller.updateFocusIfNeeded()
                self.revealScheduled = false
            }
        }

        // MARK: Transport actions

        private func updateTransportItems(on controller: AVPlayerViewController, force: Bool) {
            let formatIDs = parent.availableFormats.map { $0.id.uuidString }.joined(separator: ",")
            let captionIDs = parent.availableCaptions.map(\.id).joined(separator: ",")
            let audioIDs = parent.availableAudioTracks.map(\.id).joined(separator: ",")
            let signature = [
                String(describing: parent.likeStatus),
                String(parent.isInWatchLater),
                String(parent.isSubscribed),
                String(parent.isSignedIn),
                formatIDs,
                captionIDs,
                audioIDs,
                parent.selectedFormatID?.uuidString ?? "",
                parent.selectedCaptionID ?? "",
                parent.selectedAudioTrackID ?? ""
            ].joined(separator: "|")
            guard force || signature != menuSignature else { return }
            menuSignature = signature

            var items: [UIMenuElement] = []
            if parent.isSignedIn {
                items.append(makeSubscribeAction())
                items.append(makeLikeAction())
                items.append(makeDislikeAction())
                items.append(makeWatchLaterAction())
            }
            if !parent.availableCaptions.isEmpty {
                items.append(makeCaptionsMenu())
            }
            if parent.availableAudioTracks.count > 1 {
                items.append(makeAudioMenu())
            }
            if !parent.availableFormats.isEmpty {
                items.append(makeQualityMenu())
            }
            controller.transportBarCustomMenuItems = items
        }

        private func makeSubscribeAction() -> UIAction {
            let subscribed = parent.isSubscribed
            let title = subscribed
                ? String(localized: "Unsubscribe", bundle: .module)
                : String(localized: "Subscribe", bundle: .module)
            let icon = subscribed ? "bell.fill" : "bell"
            return UIAction(title: title, image: UIImage(systemName: icon)) { [weak self] _ in
                guard let self else { return }
                self.parent.onToggleSubscription()
            }
        }

        private func makeLikeAction() -> UIAction {
            let liked = parent.likeStatus == .like
            let title = String(localized: "Like", bundle: .module)
            let icon = liked ? "hand.thumbsup.fill" : "hand.thumbsup"
            return UIAction(
                title: title,
                image: UIImage(systemName: icon),
                state: liked ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                self.parent.onLike()
            }
        }

        private func makeDislikeAction() -> UIAction {
            let disliked = parent.likeStatus == .dislike
            let title = String(localized: "Dislike", bundle: .module)
            let icon = disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown"
            return UIAction(
                title: title,
                image: UIImage(systemName: icon),
                state: disliked ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                self.parent.onDislike()
            }
        }

        private func makeWatchLaterAction() -> UIAction {
            let added = parent.isInWatchLater
            let title = added
                ? String(localized: "Remove from Watch Later", bundle: .module)
                : String(localized: "Save to Watch Later", bundle: .module)
            let icon = added ? "clock.fill" : "clock"
            return UIAction(
                title: title,
                image: UIImage(systemName: icon),
                attributes: parent.isUpdatingWatchLater ? [.disabled] : []
            ) { [weak self] _ in
                guard let self else { return }
                self.parent.onToggleWatchLater()
            }
        }

        private func makeQualityMenu() -> UIMenu {
            var actions: [UIAction] = [
                UIAction(
                    title: String(localized: "Auto", bundle: .module),
                    state: parent.selectedFormatID == nil ? .on : .off
                ) { [weak self] _ in
                    self?.parent.onSelectFormat(nil)
                }
            ]
            actions += parent.availableFormats.map { format in
                UIAction(
                    title: format.qualityLabel,
                    state: parent.selectedFormatID == format.id ? .on : .off
                ) { [weak self] _ in
                    self?.parent.onSelectFormat(format)
                }
            }
            return UIMenu(
                title: String(localized: "Quality", bundle: .module),
                image: UIImage(systemName: "gearshape"),
                children: actions
            )
        }

        private func makeCaptionsMenu() -> UIMenu {
            var actions: [UIAction] = [
                UIAction(
                    title: String(localized: "Off", bundle: .module),
                    state: parent.selectedCaptionID == nil ? .on : .off
                ) { [weak self] _ in
                    self?.parent.onSelectCaption(nil)
                }
            ]
            actions += parent.availableCaptions.map { caption in
                UIAction(
                    title: caption.name,
                    state: parent.selectedCaptionID == caption.id ? .on : .off
                ) { [weak self] _ in
                    self?.parent.onSelectCaption(caption)
                }
            }
            return UIMenu(
                title: String(localized: "Subtitles", bundle: .module),
                image: UIImage(systemName: "captions.bubble"),
                children: actions
            )
        }

        private func makeAudioMenu() -> UIMenu {
            var actions: [UIAction] = [
                UIAction(
                    title: String(localized: "Auto", bundle: .module),
                    state: parent.selectedAudioTrackID == nil ? .on : .off
                ) { [weak self] _ in
                    self?.parent.onSelectAudioTrack(nil)
                }
            ]
            actions += parent.availableAudioTracks.map { track in
                let suffix = track.isOriginal ? " · \(String(localized: "Original", bundle: .module))" : ""
                return UIAction(
                    title: track.name + suffix,
                    state: parent.selectedAudioTrackID == track.id ? .on : .off
                ) { [weak self] _ in
                    self?.parent.onSelectAudioTrack(track)
                }
            }
            return UIMenu(
                title: String(localized: "Audio Track", bundle: .module),
                image: UIImage(systemName: "waveform"),
                children: actions
            )
        }

        // MARK: Metadata and chapters

        private func updateMetadata(on controller: AVPlayerViewController, force: Bool) {
            guard let item = controller.player?.currentItem else { return }
            let chapterKey = parent.chapters.map {
                "\($0.title):\(Int($0.startTime)):\($0.thumbnailURL?.absoluteString ?? "")"
            }.joined(separator: "|")
            let videoMetadataKey = [
                parent.video.title,
                parent.video.channelTitle,
                parent.video.description ?? "",
                parent.video.publishedAt.map { String($0.timeIntervalSince1970) } ?? "",
                parent.video.publishedTimeText ?? "",
            ].joined(separator: "|")
            let signature = "\(ObjectIdentifier(item))|\(parent.video.id)|\(Int(parent.duration))|\(videoMetadataKey)|\(chapterKey)"
            guard force || signature != metadataSignature else { return }
            metadataSignature = signature

            item.externalMetadata = makeExternalMetadata(for: parent.video)
            item.navigationMarkerGroups = makeMarkerGroups(
                chapters: parent.chapters,
                duration: parent.duration
            )
            tvSystemPlayerLog.notice(
                "[TVSystemPlayer] native tabs metadata: info=\(makeInfoDescription(for: parent.video)?.count ?? 0) chars chapters=\(parent.chapters.count) customTabs=0"
            )
            loadMissingChapterArtwork(for: item, signature: signature)
        }

        private func makeExternalMetadata(for video: Video) -> [AVMetadataItem] {
            var metadata: [AVMetadataItem] = []
            
            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            titleItem.value = video.title as NSString
            titleItem.extendedLanguageTag = "und"
            metadata.append(titleItem)
            
            if !video.channelTitle.isEmpty {
                let artistItem = AVMutableMetadataItem()
                artistItem.identifier = .commonIdentifierArtist
                artistItem.value = video.channelTitle as NSString
                artistItem.extendedLanguageTag = "und"
                metadata.append(artistItem)
            }
            
            if let description = makeInfoDescription(for: video), !description.isEmpty {
                let descItem = AVMutableMetadataItem()
                descItem.identifier = .commonIdentifierDescription
                descItem.value = description as NSString
                descItem.extendedLanguageTag = "und"
                metadata.append(descItem)
            }
            
            return metadata
        }

        private func makeInfoDescription(for video: Video) -> String? {
            var sections: [String] = []
            let publishedLabel = String(localized: "Published", bundle: .module)
            if let publishedAt = video.publishedAt {
                let date = publishedAt.formatted(
                    Date.FormatStyle(date: .long, time: .omitted).locale(.current)
                )
                sections.append("\(publishedLabel): \(date)")
            } else if let publishedTimeText = video.publishedTimeText,
                      !publishedTimeText.isEmpty {
                sections.append("\(publishedLabel): \(publishedTimeText)")
            }
            if !video.channelTitle.isEmpty {
                sections.append(video.channelTitle)
            }
            if let description = video.description, !description.isEmpty {
                sections.append(description)
            }
            return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
        }

        private func makeMarkerGroups(chapters: [Chapter], duration: TimeInterval) -> [AVNavigationMarkersGroup] {
            guard !chapters.isEmpty else { return [] }
            let markers = chapters.enumerated().map { index, chapter in
                let nextStart = chapters.indices.contains(index + 1)
                    ? chapters[index + 1].startTime
                    : max(duration, chapter.startTime)
                let markerDuration = max(1, nextStart - chapter.startTime)
                var metadata: [AVMetadataItem] = []
                
                let titleItem = AVMutableMetadataItem()
                titleItem.identifier = .commonIdentifierTitle
                titleItem.value = chapter.title as NSString
                titleItem.extendedLanguageTag = "und"
                metadata.append(titleItem)
                
                if let url = chapter.thumbnailURL, let artworkData = chapterArtwork[url] {
                    let artworkItem = AVMutableMetadataItem()
                    artworkItem.identifier = .commonIdentifierArtwork
                    artworkItem.value = artworkData as NSData
                    artworkItem.dataType = kCMMetadataBaseDataType_JPEG as String
                    artworkItem.extendedLanguageTag = "und"
                    metadata.append(artworkItem)
                }
                
                return AVTimedMetadataGroup(items: metadata, timeRange: CMTimeRange(
                    start: CMTime(seconds: chapter.startTime, preferredTimescale: 600),
                    duration: CMTime(seconds: markerDuration, preferredTimescale: 600)
                ))
            }
            return [AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: markers)]
        }

        private func loadMissingChapterArtwork(for item: AVPlayerItem, signature: String) {
            let missingURLs = parent.chapters.compactMap(\.thumbnailURL).filter { chapterArtwork[$0] == nil }
            guard !missingURLs.isEmpty else { return }
            artworkTask?.cancel()
            artworkTask = Task { @MainActor [weak self, weak item] in
                guard let self else { return }
                for url in missingURLs {
                    guard !Task.isCancelled else { return }
                    if let (data, response) = try? await URLSession.shared.data(from: url),
                       (response as? HTTPURLResponse)?.statusCode == 200 {
                        chapterArtwork[url] = data
                    }
                }
                guard !Task.isCancelled,
                      let item,
                      signature == metadataSignature else { return }
                item.navigationMarkerGroups = makeMarkerGroups(
                    chapters: parent.chapters,
                    duration: parent.duration
                )
            }
        }

        // MARK: Captions and feedback

        func installCaptionLabel(in controller: AVPlayerViewController) {
            guard let overlay = controller.contentOverlayView else { return }
            let label = TVPaddedLabel(insets: UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18))
            label.translatesAutoresizingMaskIntoConstraints = false
            label.numberOfLines = 0
            label.textAlignment = .center
            label.font = .preferredFont(forTextStyle: .title2)
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.74)
            label.layer.cornerRadius = 12
            label.layer.masksToBounds = true
            label.isAccessibilityElement = true
            label.accessibilityIdentifier = "player.captionCue"
            label.isHidden = true
            overlay.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, multiplier: 0.78),
                label.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -120),
            ])
            captionLabel = label
        }

        func installToastLabel(in controller: AVPlayerViewController) {
            guard let overlay = controller.contentOverlayView else { return }
            let label = UILabel()
            label.font = .systemFont(ofSize: 24, weight: .medium)
            label.textColor = .white
            label.textAlignment = .center
            label.numberOfLines = 2
            label.backgroundColor = UIColor.black.withAlphaComponent(0.8)
            label.layer.cornerRadius = 12
            label.layer.masksToBounds = true
            label.isHidden = true
            label.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                label.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 64),
                label.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, multiplier: 0.7),
            ])
            toastLabel = label
        }

        private func updateCaptionLabel() {
            captionLabel?.text = parent.captionText
            captionLabel?.accessibilityLabel = parent.captionText
            captionLabel?.isHidden = parent.captionText?.isEmpty != false
        }

        private func updateToastLabel() {
            guard let message = parent.toastMessage, !message.isEmpty else { return }
            guard toastLabel?.text != message || toastLabel?.isHidden == true else { return }
            toastTask?.cancel()
            toastLabel?.text = message
            toastLabel?.accessibilityLabel = message
            toastLabel?.isHidden = false
            toastTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.toastLabel?.isHidden = true
            }
        }
        
        private func formatDuration(_ seconds: TimeInterval) -> String {
            let hours = Int(seconds) / 3600
            let minutes = (Int(seconds) % 3600) / 60
            let secs = Int(seconds) % 60
            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, minutes, secs)
            } else {
                return String(format: "%d:%02d", minutes, secs)
            }
        }
    }
}

private final class TVPaddedLabel: UILabel {
    let insets: UIEdgeInsets

    init(insets: UIEdgeInsets) {
        self.insets = insets
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + insets.left + insets.right,
            height: size.height + insets.top + insets.bottom
        )
    }
}

#endif
