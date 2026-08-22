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
    let viewModel: PlaybackViewModel
    let duration: TimeInterval
    let chapters: [Chapter]
    let availableFormats: [VideoFormat]
    let selectedFormatID: UUID?
    let availableCaptions: [CaptionTrack]
    let selectedCaptionID: String?
    let isSignedIn: Bool
    let likeStatus: LikeStatus
    let isSubscribed: Bool
    let hasNext: Bool
    let captionText: String?
    let toastMessage: String?
    let isPlaylistPickerVisible: Bool
    let onDismiss: @MainActor () -> Void
    let onDismissPlaylistPicker: @MainActor () -> Void
    let onNext: @MainActor () -> Void
    let onOpenChannel: @MainActor () -> Void
    let onLike: @MainActor () -> Void
    let onDislike: @MainActor () -> Void
    let onOpenPlaylistPicker: @MainActor () -> Void
    let onToggleSubscription: @MainActor () -> Void
    let onSelectFormat: @MainActor (VideoFormat?) -> Void
    let onSelectCaption: @MainActor (CaptionTrack?) -> Void
    let onPrefetchQualities: @MainActor () -> Void

    @Environment(SettingsStore.self) var store

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
        controller.skippingBehavior = .default
        controller.isSkipBackwardEnabled = duration > 0
        controller.isSkipForwardEnabled = duration > 0
        controller.allowsPictureInPicturePlayback = true
        controller.appliesPreferredDisplayCriteriaAutomatically = true
        controller.speeds = []
        // Captions are rendered by CaptionsManager because YouTube's `tlang`
        // auto-translation tracks are external WebVTT resources. Filter the
        // embedded HLS subtitle options out of AVKit's own language control so
        // the transport bar exposes one captions button instead of two.
        controller.allowedSubtitleOptionLanguages = []

        if #available(tvOS 16.0, *) {
            controller.contextualActions = []
        }

        controller.delegate = context.coordinator
        controller.view.backgroundColor = .black
        controller.view.accessibilityIdentifier = "player.systemPlayer"

        context.coordinator.installCaptionLabel(in: controller)
        context.coordinator.installToastLabel(in: controller)
        context.coordinator.installVideoInfo()
        context.coordinator.installChaptersInfo()
        context.coordinator.installCommentsInfo()
        context.coordinator.installCustomInfoControllers(in: controller)
        context.coordinator.installRemoteNavigationHandlers(in: controller)
        context.coordinator.transportControlsInitiallyVisible()
        context.coordinator.update(controller: controller, force: true)
        context.coordinator.updatePlaylistPickerOverlay(in: controller)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.parent = self
        if controller.player !== player { controller.player = player }
        if controller.videoGravity != videoGravity { controller.videoGravity = videoGravity }
        context.coordinator.update(controller: controller, force: false)
        context.coordinator.updatePlaylistPickerOverlay(in: controller)
    }

    static func dismantleUIViewController(
        _ controller: AVPlayerViewController,
        coordinator: Coordinator
    ) {
        // AVKit keeps the currently selected custom Info controller alive while
        // its owning player controller remains in the hierarchy. Clear the tab
        // controllers before dismantling so a full-screen dismissal cannot leave
        // the Info surface composited above the destination underneath it.
        controller.customInfoViewControllers = []
        coordinator.tearDown()
        controller.delegate = nil
        controller.player = nil
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: TVSystemPlayerView
        private var captionLabel: UILabel?
        private var headerPositionContainer: UIView?
        private var headerContainer: UIView?
        private var headerAvatarImageView: UIImageView?
        private var headerAvatarChannelID: String?
        private var headerAvatarTask: Task<Void, Never>?
        private var headerTitleLabel: UILabel?
        private var headerMetadataLabel: UILabel?
        private var toastLabel: UILabel?
        private var toastContainer: UIVisualEffectView?
        private var toastTask: Task<Void, Never>?
        private var lastDisplayedToastMessage: String?
        private var metadataSignature: String = ""
        private var menuSignature: String = ""
        private var chapterArtwork: [URL: Data] = [:]
        private var metadataArtworkData: Data?
        private var metadataArtworkChannelID: String?
        private var metadataArtworkTask: Task<Void, Never>?
        private var artworkTask: Task<Void, Never>?
        private var legibleSuppressionTask: Task<Void, Never>?
        private weak var legibleSuppressedItem: AVPlayerItem?
        private var didPrefetchQualities = false
        private weak var menuPressRecognizer: UITapGestureRecognizer?
        private weak var playerController: AVPlayerViewController?
        private var playlistHostingController: TVPlaylistOverlayHost?
        private var descriptionHostingController: TVVideoDescriptionHost?
        private var infoHostingController: TVPlayerInfoHostingController<TVVideoInfoView>?
        private var chaptersHostingController: TVPlayerInfoHostingController<TVChaptersInfoView>?
        private var commentsHostingController: TVPlayerInfoHostingController<TVCommentsInfoView>?
        private var renderedChapters: [Chapter]?
        private var renderedCurrentChapterID: UUID?
        private var renderedVideoInfoState: VideoInfoRenderState?
        private var commentsInfoVideoID: String?
        private var playlistPickerVisibility: Bool?
        private var transportBarVisible = false
        private enum InfoTabID: Hashable {
            case info
            case chapters
            case comments
        }
        private var visibleInfoTabs: Set<InfoTabID> = []
        private var headerRestoreWorkItem: DispatchWorkItem?
        private var headerVisibilityRevision: UInt = 0
        private var headerAnimationTargetVisible: Bool?
        private var isObservingFocusUpdates = false
        private var systemTitleBaseFontSizes: [ObjectIdentifier: CGFloat] = [:]
        private var dismissRequested = false
        private let infoTabPreferredHeight = TVPlayerInfoTabLayout.preferredHeight
        private let systemTitleFontScale: CGFloat = 0.70

        init(parent: TVSystemPlayerView) {
            self.parent = parent
        }

        private struct VideoInfoRenderState: Equatable {
            let video: Video
            let likeCountText: String?
            let duration: TimeInterval
            let qualityLabel: String?
            let avatarData: Data?
            let hasNextVideo: Bool
        }

        func installVideoInfo() {
            let host = TVPlayerInfoHostingController(rootView: makeVideoInfoView())
            host.title = String(localized: "Info", bundle: .module)
            host.lockPreferredContentHeight(infoTabPreferredHeight)
            host.onVisibilityChange = { [weak self] visible in
                self?.setInfoTab(.info, visible: visible)
            }
            infoHostingController = host
        }

        func installChaptersInfo() {
            let host = TVPlayerInfoHostingController(rootView: makeChaptersInfoView())
            host.title = String(localized: "Chapters", bundle: .module)
            host.lockPreferredContentHeight(infoTabPreferredHeight)
            host.allowsVisualOverflow = true
            host.onVisibilityChange = { [weak self] visible in
                self?.setInfoTab(.chapters, visible: visible)
            }
            chaptersHostingController = host
        }

        func installCommentsInfo() {
            let videoID = parent.video.id
            if !videoID.isEmpty {
                parent.viewModel.comments.load(videoId: videoID)
            }
            let host = TVPlayerInfoHostingController(
                rootView: TVCommentsInfoView(
                    commentsController: parent.viewModel.comments,
                    videoID: videoID
                )
            )
            host.title = String(localized: "Comments", bundle: .module)
            host.lockPreferredContentHeight(infoTabPreferredHeight)
            host.onVisibilityChange = { [weak self] visible in
                self?.setInfoTab(.comments, visible: visible)
            }
            commentsHostingController = host
            commentsInfoVideoID = videoID
        }

        func installCustomInfoControllers(in controller: AVPlayerViewController) {
            // Install the complete tab set exactly once. Reassigning this array
            // while AVKit is visible rebuilds its tab strip and changes the
            // vertical anchor during the next remote gesture.
            guard let infoHostingController,
                  let chaptersHostingController,
                  let commentsHostingController else { return }
            controller.customInfoViewControllers = [
                infoHostingController,
                chaptersHostingController,
                commentsHostingController,
            ]
        }

        private func setInfoTab(_ tab: InfoTabID, visible: Bool) {
            if visible {
                visibleInfoTabs.insert(tab)
                return
            }

            visibleInfoTabs.remove(tab)
        }

        private func restoreHeaderAfterLeavingInfoTabs() {
            visibleInfoTabs.removeAll()
        }

        @discardableResult
        private func advanceHeaderVisibilityRevision() -> UInt {
            headerVisibilityRevision &+= 1
            return headerVisibilityRevision
        }

        private func restoreHeaderForPlaybackFocus(
            using focusCoordinator: UIFocusAnimationCoordinator? = nil
        ) {
            let neededRestore = !visibleInfoTabs.isEmpty
                || headerContainer?.isHidden != false
                || (headerContainer?.alpha ?? 0) < 0.99
                || headerContainer?.transform.isIdentity == false

            headerRestoreWorkItem?.cancel()
            headerRestoreWorkItem = nil
            visibleInfoTabs.removeAll()
            // A focusable item outside the custom info hosts belongs to AVKit's
            // playback chrome, so its controls are visible even if the transport
            // delegate left this flag stale while collapsing an info panel.
            transportBarVisible = true

            // Focus can move through several AVKit controls during one swipe,
            // and AVKit can report the same transport reveal independently.
            // The first coordinator owns the transition; matching updates only
            // keep the canonical state current and must not restart animation.
            if headerAnimationTargetVisible == true {
                bringHeaderToFront()
                return
            }

            if neededRestore {
                tvSystemPlayerLog.notice(
                    "[TVSystemPlayer] Focus returned to playback chrome — restoring header"
                )
            }
            guard neededRestore,
                  parent.player.currentItem?.status == .readyToPlay,
                  !parent.viewModel.isLoading,
                  let header = headerContainer else {
                bringHeaderToFront()
                return
            }

            headerAnimationTargetVisible = true
            let revision = advanceHeaderVisibilityRevision()
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            let wasHidden = header.isHidden
            let currentAlpha = header.layer.presentation().map { CGFloat($0.opacity) } ?? header.alpha

            // Position is driven exclusively by AVKit's animated
            // unobscuredContentGuide. Only opacity is coordinated here; adding
            // a second translation would move the header twice.
            header.layer.removeAllAnimations()
            UIView.performWithoutAnimation {
                header.isHidden = false
                header.alpha = wasHidden ? 0 : currentAlpha
                header.transform = .identity
                bringHeaderToFront()
            }

            let animations = { [weak self, weak header] in
                guard let self, let header,
                      self.headerVisibilityRevision == revision,
                      self.headerAnimationTargetVisible == true,
                      self.visibleInfoTabs.isEmpty,
                      self.transportBarVisible else { return }
                header.alpha = 1
                header.transform = .identity
                self.bringHeaderToFront()
            }
            let completion = { [weak self, weak header] in
                guard let self,
                      self.headerVisibilityRevision == revision,
                      self.headerAnimationTargetVisible == true else { return }
                guard let header,
                      self.visibleInfoTabs.isEmpty,
                      self.transportBarVisible else { return }
                header.isHidden = false
                header.alpha = 1
                header.transform = .identity
                self.bringHeaderToFront()
            }

            if let focusCoordinator {
                focusCoordinator.addCoordinatedAnimations(animations, completion: completion)
            } else {
                UIView.animate(
                    withDuration: reduceMotion ? 0.12 : 0.25,
                    delay: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
                    animations: animations
                ) { _ in
                    completion()
                }
            }
        }

        private func scheduleHeaderRestore() {
            // AVKit briefly removes one child controller before presenting the
            // next tab. A short deferral prevents the playback header from
            // flashing between Info, Chapters, and Comments. It also lets AVKit
            // finish its interactive Back transition before restoring the header.
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.visibleInfoTabs.isEmpty else { return }
                self.showHeaderImmediatelyIfReady()
            }
            headerRestoreWorkItem?.cancel()
            headerRestoreWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
        }

        private func hideHeaderForInfoPanel() {
            headerAnimationTargetVisible = false
            advanceHeaderVisibilityRevision()
            headerContainer?.layer.removeAllAnimations()
            headerContainer?.alpha = 0
            headerContainer?.isHidden = true
            headerContainer?.transform = .identity
        }

        private func makeVideoInfoView() -> TVVideoInfoView {
            let qualityLabel = parent.availableFormats.first(where: { $0.id == parent.selectedFormatID })?.label
            let avatarImage = metadataArtworkData.flatMap(UIImage.init(data:))
            return TVVideoInfoView(
                video: parent.video,
                likeCountText: parent.viewModel.likeCountText,
                duration: parent.duration,
                qualityLabel: qualityLabel,
                avatarImage: avatarImage,
                hasNextVideo: parent.hasNext,
                canOpenChannel: parent.video.channelId?.isEmpty == false,
                onPlayFromBeginning: { [weak self] in
                    guard let self else { return }
                    self.parent.player.seek(
                        to: .zero,
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                    self.parent.player.play()
                },
                onPlayNext: { [weak self] in
                    self?.playNextFromInfoPanel()
                },
                onOpenChannel: { [weak self] in
                    self?.openChannelFromInfoPanel()
                },
                onShowDescription: { [weak self] in
                    self?.presentDescription()
                }
            )
        }

        private func openChannelFromInfoPanel() {
            // Remove the active AVKit Info surface first. The owner then dismisses
            // the full-screen player and routes the channel in the app's main
            // NavigationStack, where the tvOS top tab bar remains available.
            let onOpenChannel = parent.onOpenChannel
            visibleInfoTabs.removeAll()
            playerController?.customInfoViewControllers = []
            DispatchQueue.main.async {
                onOpenChannel()
            }
        }

        private func playNextFromInfoPanel() {
            guard parent.hasNext else { return }
            // Keep AVKit's active info controller and focus hierarchy intact while
            // the shared player swaps its item. Menu/Back therefore remains owned
            // by the same AVPlayerViewController throughout the transition.
            parent.onNext()
        }

        private func makeChaptersInfoView() -> TVChaptersInfoView {
            TVChaptersInfoView(
                chapters: parent.chapters,
                currentTime: parent.viewModel.currentTime,
                onSelectChapter: { [weak self] chapter in
                    guard let self else { return }
                    self.parent.player.seek(
                        to: CMTime(seconds: chapter.startTime, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                    self.parent.player.play()
                }
            )
        }

        private func updateVideoInfo(force: Bool = false) {
            guard let host = infoHostingController else { return }
            let qualityLabel = parent.availableFormats.first(
                where: { $0.id == parent.selectedFormatID }
            )?.label
            let state = VideoInfoRenderState(
                video: parent.video,
                likeCountText: parent.viewModel.likeCountText,
                duration: parent.duration,
                qualityLabel: qualityLabel,
                avatarData: metadataArtworkData,
                hasNextVideo: parent.hasNext
            )
            guard force || state != renderedVideoInfoState else { return }
            host.rootView = makeVideoInfoView()
            renderedVideoInfoState = state
        }

        private func updateChaptersInfo(force: Bool) {
            guard let host = chaptersHostingController else { return }
            let currentChapterID = parent.chapters.last(
                where: { $0.startTime <= parent.viewModel.currentTime }
            )?.id
            guard force
                    || renderedChapters != parent.chapters
                    || renderedCurrentChapterID != currentChapterID else { return }

            host.rootView = makeChaptersInfoView()
            renderedChapters = parent.chapters
            renderedCurrentChapterID = currentChapterID
        }

        func transportControlsInitiallyVisible() {
            transportBarVisible = true
        }

        private func updateCommentsInfoIfNeeded() {
            guard let host = commentsHostingController,
                  let videoID = commentsInfoVideoID,
                  videoID != parent.video.id,
                  !parent.video.id.isEmpty else { return }
            parent.viewModel.comments.load(videoId: parent.video.id)
            host.rootView = TVCommentsInfoView(
                commentsController: parent.viewModel.comments,
                videoID: parent.video.id
            )
            commentsInfoVideoID = parent.video.id
        }

        func update(controller: AVPlayerViewController, force: Bool) {
            controller.isSkipBackwardEnabled = parent.duration > 0
            controller.isSkipForwardEnabled = parent.duration > 0
            let pickerVisible = parent.isPlaylistPickerVisible
            if playlistPickerVisibility != pickerVisible {
                playlistPickerVisibility = pickerVisible
                controller.showsPlaybackControls = !pickerVisible
            }

            updateTransportItems(on: controller, force: force)
            suppressEmbeddedCaptionsIfNeeded(on: controller)
            updateMetadata(on: controller, force: force)
            updateVideoInfo(force: force)
            updateChaptersInfo(force: force)
            updateCommentsInfoIfNeeded()
            updateCaptionLabel()
            updateToastLabel()

            if !didPrefetchQualities, !parent.availableFormats.isEmpty {
                didPrefetchQualities = true
                parent.onPrefetchQualities()
            }
        }

        func updatePlaylistPickerOverlay(in controller: AVPlayerViewController) {
            if !parent.isPlaylistPickerVisible {
                guard let host = playlistHostingController else { return }
                playlistHostingController = nil
                if host.presentingViewController != nil {
                    host.dismiss(animated: true)
                }
                return
            }

            guard playlistHostingController == nil else { return }

            let host = TVPlaylistOverlayHost(
                rootView: TVPlaylistPickerOverlay(
                    viewModel: parent.viewModel,
                    onDismiss: { [weak self] in
                        self?.parent.onDismissPlaylistPicker()
                    }
                )
            )
            host.modalPresentationStyle = .overFullScreen
            host.modalTransitionStyle = .crossDissolve
            host.view.backgroundColor = .clear
            host.onHostDismissed = { [weak self] in
                self?.parent.onDismissPlaylistPicker()
            }
            playlistHostingController = host
            controller.present(host, animated: true)
        }

        private func presentDescription() {
            guard descriptionHostingController == nil,
                  let controller = playerController else { return }

            let video = parent.video
            let host = TVVideoDescriptionHost(
                rootView: TVVideoDescriptionOverlay(
                    title: video.title,
                    channelTitle: video.channelTitle,
                    description: video.description ?? "",
                    onDismiss: { [weak self] in
                        self?.dismissDescription(animated: true)
                    }
                )
            )
            host.modalPresentationStyle = .overFullScreen
            host.modalTransitionStyle = .crossDissolve
            host.view.backgroundColor = .clear
            host.onHostDismissed = { [weak self, weak host] in
                guard let self, self.descriptionHostingController === host else { return }
                self.descriptionHostingController = nil
            }
            descriptionHostingController = host
            tvSystemPlayerLog.notice("[TVSystemPlayer] presenting Description above AVKit")

            // AVKit keeps private presentation controllers alive while its Info
            // panel is visible. Requiring `presentedViewController == nil` made
            // View More silently do nothing. Present from the visible Info host
            // when possible and let UIKit resolve its full-screen ancestor.
            let presenter: UIViewController
            if let infoHostingController,
               infoHostingController.viewIfLoaded?.window != nil,
               !infoHostingController.isBeingDismissed {
                presenter = infoHostingController
            } else if let visibleController = controller.presentedViewController,
                      visibleController.viewIfLoaded?.window != nil,
                      !visibleController.isBeingDismissed {
                presenter = visibleController
            } else {
                presenter = controller
            }
            presenter.present(host, animated: true)
        }

        private func dismissDescription(animated: Bool) {
            guard let host = descriptionHostingController else { return }
            descriptionHostingController = nil
            let controller = playerController
            host.dismiss(animated: animated) {
                controller?.setNeedsFocusUpdate()
                controller?.updateFocusIfNeeded()
            }
        }

        func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
            if descriptionHostingController != nil {
                dismissDescription(animated: true)
                return false
            }
            if parent.isPlaylistPickerVisible {
                parent.onDismissPlaylistPicker()
                return false
            }
            if !visibleInfoTabs.isEmpty {
                visibleInfoTabs.removeAll()
                return false
            }
            // Menu at an active AVKit child level (Info, Chapters, Comments,
            // transport actions, or the timeline) must stay inside the Player.
            // The player is dismissible only after its chrome has disappeared.
            if transportBarVisible { return false }
            dismissPlayerOnce()
            return false
        }

        func skipToNextItem(for playerViewController: AVPlayerViewController) {
            parent.viewModel.seekRelative(seconds: Double(parent.store.settings.seekForwardSeconds))
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willTransitionToVisibilityOfTransportBar visible: Bool,
            with coordinator: any AVPlayerViewControllerAnimationCoordinator
        ) {
            transportBarVisible = visible
            if visible {
                compactSystemTitleFont(in: playerViewController)
            }
            let playerReady = parent.player.currentItem?.status == .readyToPlay && !parent.viewModel.isLoading
            let targetVisible = visible && playerReady

            // A focus update and AVKit's transport callback can describe the
            // same reveal. Whichever coordinator starts first remains the only
            // animation owner, preventing a second take-over mid-flight.
            if headerAnimationTargetVisible == targetVisible {
                bringHeaderToFront()
                return
            }

            headerAnimationTargetVisible = targetVisible
            let revision = advanceHeaderVisibilityRevision()
            if targetVisible, headerContainer?.isHidden == true {
                headerContainer?.isHidden = false
                headerContainer?.alpha = 0
                headerContainer?.transform = .identity
            }
            bringHeaderToFront()
            coordinator.addCoordinatedAnimations { [weak self] in
                guard let self,
                      self.headerVisibilityRevision == revision,
                      self.headerAnimationTargetVisible == targetVisible else { return }
                if visible {
                    self.compactSystemTitleFont(in: playerViewController)
                }
                self.bringHeaderToFront()
                self.headerContainer?.alpha = targetVisible ? 1 : 0
                self.headerContainer?.transform = .identity
            } completion: { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.headerVisibilityRevision == revision,
                          self.headerAnimationTargetVisible == targetVisible else { return }
                    if visible {
                        self.compactSystemTitleFont(in: playerViewController)
                    }
                    self.bringHeaderToFront()
                    let playerReady = self.parent.player.currentItem?.status == .readyToPlay
                        && !self.parent.viewModel.isLoading
                    let shouldShow = self.transportBarVisible
                        && playerReady
                    self.headerContainer?.isHidden = !shouldShow
                    self.headerContainer?.alpha = shouldShow ? 1 : 0
                    self.headerContainer?.transform = .identity
                }
            }
        }

        func skipToPreviousItem(for playerViewController: AVPlayerViewController) {
            parent.viewModel.seekRelative(seconds: -Double(parent.store.settings.seekBackSeconds))
        }

        func installRemoteNavigationHandlers(in controller: AVPlayerViewController) {
            playerController = controller
            startObservingFocusUpdates()

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

            // Keep the native AVKit controller in the responder chain. No SwiftUI
            // focusable/onMoveCommand layer is allowed above it.
            DispatchQueue.main.async { [weak controller] in
                guard let controller else { return }
                _ = controller.becomeFirstResponder()
                controller.setNeedsFocusUpdate()
                controller.updateFocusIfNeeded()
            }
        }

        private func startObservingFocusUpdates() {
            guard !isObservingFocusUpdates else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleFocusDidUpdate(_:)),
                name: UIFocusSystem.didUpdateNotification,
                object: nil
            )
            isObservingFocusUpdates = true
        }

        func tearDown() {
            dismissDescription(animated: false)
            legibleSuppressionTask?.cancel()
            legibleSuppressionTask = nil
            legibleSuppressedItem = nil
            if isObservingFocusUpdates {
                NotificationCenter.default.removeObserver(
                    self,
                    name: UIFocusSystem.didUpdateNotification,
                    object: nil
                )
                isObservingFocusUpdates = false
            }
            headerRestoreWorkItem?.cancel()
            headerRestoreWorkItem = nil
            headerAnimationTargetVisible = nil
            systemTitleBaseFontSizes.removeAll()
        }

        @objc private func handleFocusDidUpdate(_ notification: Notification) {
            guard let controller = playerController,
                  controller.viewIfLoaded?.window != nil,
                  let playerFocusSystem = UIFocusSystem.focusSystem(for: controller.view),
                  let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                    as? UIFocusUpdateContext else { return }

            if let postedFocusSystem = notification.object as? UIFocusSystem,
               postedFocusSystem !== playerFocusSystem {
                return
            }

            let nextItem = context.nextFocusedItem ?? playerFocusSystem.focusedItem
            let nextView = context.nextFocusedView
            guard focusItem(nextItem, focusedView: nextView, isInside: controller.view) else {
                return
            }

            if let focusedTab = infoTab(containing: nextItem, focusedView: nextView) {
                visibleInfoTabs = [focusedTab]
                return
            }

            visibleInfoTabs.removeAll()
        }

        private func infoTab(
            containing item: (any UIFocusItem)?,
            focusedView: UIView?
        ) -> InfoTabID? {
            if let view = commentsHostingController?.viewIfLoaded,
               focusItem(item, focusedView: focusedView, isInside: view) {
                return .comments
            }
            if let view = chaptersHostingController?.viewIfLoaded,
               focusItem(item, focusedView: focusedView, isInside: view) {
                return .chapters
            }
            if let view = infoHostingController?.viewIfLoaded,
               focusItem(item, focusedView: focusedView, isInside: view) {
                return .info
            }
            return nil
        }

        private func focusItem(
            _ item: (any UIFocusItem)?,
            focusedView: UIView?,
            isInside container: UIView
        ) -> Bool {
            if let item, container.contains(item) { return true }
            guard let focusedView else { return false }
            return focusedView === container || focusedView.isDescendant(of: container)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Only menuPress may run alongside AVKit's own recognizers so our
            // Back action still wins. AVKit owns horizontal pan for its native
            // transport bar / chapter strip / info tabs — we do NOT install a
            // custom scrub recognizer anymore.
            gestureRecognizer === menuPressRecognizer
                || otherGestureRecognizer === menuPressRecognizer
        }

        // Observe only Menu/Back. Directional gestures remain entirely owned by
        // AVKit, so scrolling a tab can never rebuild or reposition its chrome.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === menuPressRecognizer {
                if parent.isPlaylistPickerVisible { return true }
                if !visibleInfoTabs.isEmpty {
                    // Observe Back from an AVKit info tab without consuming it.
                    // AVKit performs the native pop; we only release the custom
                    // playback header state that its child lifecycle can retain.
                    restoreHeaderAfterLeavingInfoTabs()
                    return false
                }
                return !transportBarVisible
            }
            return true
        }

        @objc private func handleMenuPress(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            if parent.isPlaylistPickerVisible {
                parent.onDismissPlaylistPicker()
                return
            }
            dismissPlayerOnce()
        }

        private func dismissPlayerOnce() {
            guard !dismissRequested else { return }
            dismissRequested = true
            tvSystemPlayerLog.notice("[TVSystemPlayer] Back/Menu pressed — dismissing player immediately")
            parent.onDismiss()
        }

        // MARK: Transport actions

        private func updateTransportItems(on controller: AVPlayerViewController, force: Bool) {
            let formatIDs = parent.availableFormats.map { $0.id.uuidString }.joined(separator: ",")
            let captionIDs = parent.availableCaptions.map(\.id).joined(separator: ",")
            let signature = [
                String(describing: parent.likeStatus),
                String(parent.isSubscribed),
                String(parent.isSignedIn),
                formatIDs,
                captionIDs,
                parent.selectedFormatID?.uuidString ?? "",
                parent.selectedCaptionID ?? ""
            ].joined(separator: "|")
            guard force || signature != menuSignature else { return }
            menuSignature = signature

            var items: [UIMenuElement] = []
            if parent.isSignedIn {
                items.append(makeSubscribeAction())
                items.append(makeLikeAction())
                items.append(makeDislikeAction())
                items.append(makePlaylistAction())
            }
            if !parent.availableCaptions.isEmpty {
                items.append(makeCaptionsMenu())
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
            let icon = subscribed ? "person.badge.minus" : "person.badge.plus"
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

        private func makePlaylistAction() -> UIAction {
            UIAction(
                title: String(localized: "Add to Playlist", bundle: .module),
                image: UIImage(systemName: "rectangle.stack.badge.plus")
            ) { [weak self] _ in
                self?.parent.onOpenPlaylistPicker()
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
            var children: [UIMenuElement] = actions
            if let source = captionTranslationSource(), !source.translationLanguages.isEmpty {
                let translatedActions = source.translationLanguages.compactMap { language -> UIAction? in
                    guard let translated = source.translated(to: language) else { return nil }
                    return UIAction(
                        title: language.name,
                        state: parent.selectedCaptionID == translated.id ? .on : .off
                    ) { [weak self] _ in
                        self?.parent.onSelectCaption(translated)
                    }
                }
                if !translatedActions.isEmpty {
                    children.append(UIMenu(
                        title: String(localized: "Auto-translate", bundle: .module),
                        image: UIImage(systemName: "globe"),
                        children: translatedActions
                    ))
                }
            }
            return UIMenu(
                title: String(localized: "Subtitles", bundle: .module),
                image: UIImage(systemName: "captions.bubble"),
                children: children
            )
        }

        private func captionTranslationSource() -> CaptionTrack? {
            if let selectedID = parent.selectedCaptionID {
                if let selectedSource = parent.availableCaptions.first(where: { $0.id == selectedID }) {
                    return selectedSource
                }
                if let translatedSource = parent.availableCaptions.first(where: {
                    selectedID.hasPrefix("\($0.id)|tlang=")
                }) {
                    return translatedSource
                }
            }
            return parent.availableCaptions.first
        }

        private func suppressEmbeddedCaptionsIfNeeded(on controller: AVPlayerViewController) {
            guard let item = controller.player?.currentItem,
                  item !== legibleSuppressedItem else { return }
            legibleSuppressedItem = item
            legibleSuppressionTask?.cancel()
            legibleSuppressionTask = Task { @MainActor [weak self, weak item] in
                guard let item,
                      let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                      !Task.isCancelled else { return }
                item.select(nil, in: group)
                self?.legibleSuppressionTask = nil
            }
        }

        // MARK: Metadata and chapters

        private func updateMetadata(on controller: AVPlayerViewController, force: Bool) {
            guard let item = controller.player?.currentItem else { return }
            prepareMetadataArtwork(for: parent.video)
            guard !parent.viewModel.isLoading else { return }
            let chapterKey = parent.chapters.map {
                "\($0.title):\(Int($0.startTime)):\($0.thumbnailURL?.absoluteString ?? "")"
            }.joined(separator: "|")
            let videoMetadataKey = [
                parent.video.title,
                parent.video.channelTitle,
                parent.video.formattedViewCount,
                parent.viewModel.likeCountText ?? "",
                parent.video.description ?? "",
                parent.video.publishedAt.map { String($0.timeIntervalSince1970) } ?? "",
                parent.video.publishedTimeText ?? "",
                metadataArtworkData == nil ? "no-artwork" : "artwork",
            ].joined(separator: "|")
            let signature = "\(ObjectIdentifier(item))|\(parent.video.id)|\(Int(parent.duration))|\(videoMetadataKey)|\(chapterKey)"
            guard force || signature != metadataSignature else { return }
            metadataSignature = signature

            // The compact system transport label consumes only subtitle metadata.
            // Common title, artwork, and description stay out of externalMetadata
            // because they make AVKit add its own Info tab beside our custom one.
            item.externalMetadata = makeExternalMetadata(for: parent.video)
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.compactSystemTitleFont(in: controller)
            }
            // Chapters is also custom so AVKit preserves the explicit tab order:
            // Info, Chapters, Comments.
            item.navigationMarkerGroups = []
            tvSystemPlayerLog.notice(
                "[TVSystemPlayer] custom Info: description=\(parent.video.description?.count ?? 0) chars likes=\(parent.viewModel.likeCountText ?? "nil") chapters=\(parent.chapters.count)"
            )
        }

        private func makeExternalMetadata(for video: Video) -> [AVMetadataItem] {
            let compactTitle = makeCompactTransportTitle(for: video)
            guard !compactTitle.isEmpty else { return [] }

            // AVKit's title font is fixed and intentionally large. Supplying
            // only the supported subtitle key keeps the view fully system-owned
            // while using its smaller native text style. Avoiding the common
            // title/artwork/description keys also prevents the metadata Info tab.
            let subtitleItem = AVMutableMetadataItem()
            subtitleItem.identifier = .iTunesMetadataTrackSubTitle
            subtitleItem.value = compactTitle as NSString
            subtitleItem.extendedLanguageTag = "und"
            return [subtitleItem]
        }

        private func makeCompactTransportTitle(for video: Video) -> String {
            let details = makeMetadataSubtitle(for: video)
            return [video.title, details]
                .filter { !$0.isEmpty }
                .joined(separator: "  ·  ")
        }

        private func compactSystemTitleFont(in controller: AVPlayerViewController) {
            let expectedTitle = makeCompactTransportTitle(for: parent.video)
            guard !expectedTitle.isEmpty, controller.isViewLoaded else { return }
            controller.view.layoutIfNeeded()
            compactSystemTitleFont(in: controller.view, matching: expectedTitle)
        }

        private func compactSystemTitleFont(in view: UIView, matching expectedTitle: String) {
            if let label = view as? UILabel,
               label.text == expectedTitle || label.accessibilityLabel == expectedTitle {
                let identifier = ObjectIdentifier(label)
                let baseSize = systemTitleBaseFontSizes[identifier] ?? label.font.pointSize
                systemTitleBaseFontSizes[identifier] = baseSize
                let targetSize = baseSize * systemTitleFontScale
                if abs(label.font.pointSize - targetSize) > 0.25 {
                    label.adjustsFontForContentSizeCategory = false
                    label.font = UIFont(descriptor: label.font.fontDescriptor, size: targetSize)
                }
            }

            for subview in view.subviews {
                compactSystemTitleFont(in: subview, matching: expectedTitle)
            }
        }

        private func makeMetadataSubtitle(for video: Video) -> String {
            var parts: [String] = []
            if !video.channelTitle.isEmpty { parts.append(video.channelTitle) }
            if !video.formattedViewCount.isEmpty { parts.append(video.formattedViewCount) }
            if let publishedTime = video.publishedTimeText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !publishedTime.isEmpty {
                parts.append(publishedTime)
            }
            return parts.joined(separator: " · ")
        }

        private func prepareMetadataArtwork(for video: Video) {
            let channelID = video.channelId?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard channelID != metadataArtworkChannelID else { return }
            metadataArtworkTask?.cancel()
            metadataArtworkChannelID = channelID
            metadataArtworkData = nil

            guard let channelID, !channelID.isEmpty else { return }
            let api = parent.viewModel.api
            let videoID = video.id
            metadataArtworkTask = Task { @MainActor [weak self] in
                guard let url = try? await api.fetchChannelThumbnailURL(channelId: channelID),
                      let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let artworkData = UIImage(data: data)?.jpegData(compressionQuality: 0.9),
                      let self,
                      self.parent.video.id == videoID,
                      self.parent.video.channelId == channelID else { return }
                self.metadataArtworkData = artworkData
                guard !self.parent.viewModel.isLoading else { return }
                self.updateVideoInfo()
                if let controller = self.playerController {
                    self.updateMetadata(on: controller, force: true)
                }
            }
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
                titleItem.value = "\(chapter.title)  \(formatDuration(chapter.startTime))" as NSString
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

        // MARK: Header, captions, and feedback

        func installHeader(in controller: AVPlayerViewController) {
            // This outer view is constrained to AVKit's animated layout guide.
            // Its position therefore follows the playback chrome exactly; the
            // inner view can fade without touching AVKit's position animation.
            let positionContainer = UIView()
            positionContainer.translatesAutoresizingMaskIntoConstraints = false
            positionContainer.isUserInteractionEnabled = false

            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.isUserInteractionEnabled = false
            container.isHidden = true

            let titleLabel = UILabel()
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.font = .systemFont(ofSize: 26, weight: .semibold)
            titleLabel.textColor = .white
            titleLabel.numberOfLines = 2
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.layer.shadowColor = UIColor.black.cgColor
            titleLabel.layer.shadowOpacity = 0.95
            titleLabel.layer.shadowRadius = 7
            titleLabel.layer.shadowOffset = CGSize(width: 0, height: 2)
            titleLabel.setContentHuggingPriority(.required, for: .vertical)
            titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

            let metadataLabel = UILabel()
            metadataLabel.translatesAutoresizingMaskIntoConstraints = false
            metadataLabel.font = .systemFont(ofSize: 24, weight: .medium)
            metadataLabel.textColor = .white
            metadataLabel.numberOfLines = 1
            metadataLabel.lineBreakMode = .byTruncatingTail
            metadataLabel.layer.shadowColor = UIColor.black.cgColor
            metadataLabel.layer.shadowOpacity = 0.95
            metadataLabel.layer.shadowRadius = 6
            metadataLabel.layer.shadowOffset = CGSize(width: 0, height: 1)
            metadataLabel.setContentHuggingPriority(.required, for: .vertical)
            metadataLabel.setContentCompressionResistancePriority(.required, for: .vertical)

            let avatar = TVRoundImageView()
            avatar.translatesAutoresizingMaskIntoConstraints = false
            avatar.contentMode = .scaleAspectFill
            avatar.clipsToBounds = true
            avatar.backgroundColor = UIColor.white.withAlphaComponent(0.16)
            avatar.isAccessibilityElement = false

            container.addSubview(avatar)
            container.addSubview(titleLabel)
            container.addSubview(metadataLabel)
            positionContainer.addSubview(container)
            controller.view.addSubview(positionContainer)

            NSLayoutConstraint.activate([
                positionContainer.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 84),
                positionContainer.bottomAnchor.constraint(
                    equalTo: controller.unobscuredContentGuide.bottomAnchor,
                    constant: -64
                ),
                positionContainer.trailingAnchor.constraint(equalTo: controller.view.centerXAnchor, constant: -44),
                container.leadingAnchor.constraint(equalTo: positionContainer.leadingAnchor),
                container.topAnchor.constraint(equalTo: positionContainer.topAnchor),
                container.trailingAnchor.constraint(equalTo: positionContainer.trailingAnchor),
                container.bottomAnchor.constraint(equalTo: positionContainer.bottomAnchor),
                avatar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                avatar.topAnchor.constraint(equalTo: container.topAnchor),
                avatar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                avatar.widthAnchor.constraint(equalTo: avatar.heightAnchor),
                titleLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 14),
                titleLabel.topAnchor.constraint(equalTo: container.topAnchor),
                titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                metadataLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                metadataLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3.5),
                metadataLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                metadataLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])

            container.isAccessibilityElement = true
            headerPositionContainer = positionContainer
            headerContainer = container
            headerAvatarImageView = avatar
            headerTitleLabel = titleLabel
            headerMetadataLabel = metadataLabel
            updateHeader()
            bringHeaderToFront()
        }

        private func updateHeader() {
            headerTitleLabel?.text = parent.video.title

            var parts: [String] = []
            if !parent.video.channelTitle.isEmpty {
                parts.append(parent.video.channelTitle)
            }
            if !parent.video.formattedViewCount.isEmpty {
                parts.append(parent.video.formattedViewCount)
            }
            if let publishedTime = parent.video.publishedTimeText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !publishedTime.isEmpty {
                parts.append(publishedTime)
            }

            let metadata = parts.joined(separator: "  ·  ")
            headerMetadataLabel?.text = metadata
            headerMetadataLabel?.isHidden = parts.isEmpty
            headerContainer?.accessibilityLabel = [parent.video.title, metadata]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            updateHeaderAvatar()
            bringHeaderToFront()
        }

        private func showHeaderImmediatelyIfReady() {
            guard transportBarVisible,
                  parent.player.currentItem?.status == .readyToPlay,
                  !parent.viewModel.isLoading,
                  let header = headerContainer else { return }
            // SwiftUI updates and the delayed lifecycle fallback may arrive
            // while a coordinated reveal is running. They may bring the view
            // forward, but must not snap its model layer to the end state.
            guard headerAnimationTargetVisible != true else {
                bringHeaderToFront()
                return
            }
            headerAnimationTargetVisible = true
            advanceHeaderVisibilityRevision()
            header.layer.removeAllAnimations()
            header.alpha = 1
            header.isHidden = false
            header.transform = .identity
            bringHeaderToFront()
        }

        private func bringHeaderToFront() {
            guard let positionContainer = headerPositionContainer ?? headerContainer else { return }
            positionContainer.superview?.bringSubviewToFront(positionContainer)
        }

        private func updateHeaderAvatar() {
            let channelID = parent.video.channelId?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard channelID != headerAvatarChannelID else { return }
            headerAvatarChannelID = channelID
            headerAvatarTask?.cancel()
            headerAvatarImageView?.image = nil

            guard let channelID, !channelID.isEmpty else { return }
            let api = parent.viewModel.api
            let videoID = parent.video.id
            headerAvatarTask = Task { @MainActor [weak self] in
                guard let url = try? await api.fetchChannelThumbnailURL(channelId: channelID),
                      let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = UIImage(data: data),
                      let self,
                      self.parent.video.id == videoID,
                      self.parent.video.channelId == channelID else { return }
                self.headerAvatarImageView?.image = image
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
            let container = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
            container.layer.cornerRadius = 20
            container.layer.cornerCurve = .continuous
            container.layer.masksToBounds = true
            container.layer.borderWidth = 1
            container.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
            container.isHidden = true
            container.translatesAutoresizingMaskIntoConstraints = false

            let label = UILabel()
            label.font = .systemFont(ofSize: 22, weight: .semibold)
            label.textColor = .white
            label.textAlignment = .center
            label.numberOfLines = 1
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.8
            label.translatesAutoresizingMaskIntoConstraints = false
            container.contentView.addSubview(label)
            overlay.addSubview(container)
            NSLayoutConstraint.activate([
                container.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                container.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 72),
                container.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, multiplier: 0.58),
                container.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
                label.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor, constant: -24),
                label.topAnchor.constraint(equalTo: container.contentView.topAnchor, constant: 14),
                label.bottomAnchor.constraint(equalTo: container.contentView.bottomAnchor, constant: -14),
            ])
            toastLabel = label
            toastContainer = container
        }

        private func updateCaptionLabel() {
            captionLabel?.text = parent.captionText
            captionLabel?.accessibilityLabel = parent.captionText
            captionLabel?.isHidden = parent.captionText?.isEmpty != false
        }

        private func updateToastLabel() {
            guard let message = parent.toastMessage, !message.isEmpty else {
                lastDisplayedToastMessage = nil
                return
            }
            guard message != lastDisplayedToastMessage else { return }
            lastDisplayedToastMessage = message
            toastTask?.cancel()
            toastLabel?.text = message
            toastLabel?.accessibilityLabel = message
            toastContainer?.isHidden = false
            toastTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.toastContainer?.isHidden = true
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

@MainActor
private final class TVPlayerInfoHostingController<Content: View>: UIHostingController<Content> {
    var onVisibilityChange: ((Bool) -> Void)?
    var allowsVisualOverflow = false {
        didSet { updateClippingBehavior() }
    }
    private var lockedPreferredContentHeight: CGFloat?

    func lockPreferredContentHeight(_ height: CGFloat) {
        // SwiftUI content changes (pagination, focus, a new current chapter)
        // must never feed a new intrinsic size back into AVKit.
        sizingOptions = []
        safeAreaRegions = []
        lockedPreferredContentHeight = height
        super.preferredContentSize = CGSize(width: 0, height: height)
        view.backgroundColor = .clear
        view.insetsLayoutMarginsFromSafeArea = false
        view.directionalLayoutMargins = .zero
        updateClippingBehavior()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateClippingBehavior()

        // AVKit wraps every custom tab in its own container. Chapters needs to
        // draw focused scale and shadows beyond that wrapper without changing
        // the wrapper's measured size or the shared tab-strip position.
        guard allowsVisualOverflow else { return }
        view.superview?.clipsToBounds = false
        view.superview?.layer.masksToBounds = false
    }

    private func updateClippingBehavior() {
        view.clipsToBounds = !allowsVisualOverflow
        view.layer.masksToBounds = !allowsVisualOverflow
    }

    override var preferredContentSize: CGSize {
        get {
            let size = super.preferredContentSize
            guard let lockedPreferredContentHeight else { return size }
            return CGSize(width: size.width, height: lockedPreferredContentHeight)
        }
        set {
            guard let lockedPreferredContentHeight else {
                super.preferredContentSize = newValue
                return
            }
            super.preferredContentSize = CGSize(
                width: newValue.width,
                height: lockedPreferredContentHeight
            )
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        onVisibilityChange?(true)
    }

    // AVKit's interactive collapse exposes the transport chrome before the info
    // child has fully disappeared, so release the header at transition start.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onVisibilityChange?(false)
    }

    override func didUpdateFocus(
        in context: UIFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        super.didUpdateFocus(in: context, with: coordinator)

        let focusWasInside = context.previouslyFocusedItem.map { view.contains($0) } ?? false
        let focusIsInside = context.nextFocusedItem.map { view.contains($0) } ?? false
        guard focusWasInside != focusIsInside else { return }

        // AVKit keeps custom info controllers attached when an upward swipe
        // moves focus back to playback controls. Observe that native focus
        // transition so the playback header is restored without intercepting
        // the Siri Remote gesture.
        onVisibilityChange?(focusIsInside)
    }
}

private final class TVRoundImageView: UIImageView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
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
