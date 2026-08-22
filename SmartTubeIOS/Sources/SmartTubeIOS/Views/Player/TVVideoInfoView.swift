#if os(tvOS)
import SwiftUI
import SmartTubeIOSCore

struct TVVideoInfoView: View {
    private enum FocusedAction: Hashable {
        case viewMore
        case playFromBeginning
        case playNext
        case openChannel
    }

    let video: Video
    let likeCountText: String?
    let duration: TimeInterval
    let qualityLabel: String?
    let avatarImage: UIImage?
    let hasNextVideo: Bool
    let canOpenChannel: Bool
    let onPlayFromBeginning: @MainActor () -> Void
    let onPlayNext: @MainActor () -> Void
    let onOpenChannel: @MainActor () -> Void
    let onShowDescription: @MainActor () -> Void

    @FocusState private var focusedAction: FocusedAction?

    private var trimmedDescription: String {
        video.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var publishedText: String? {
        if let publishedAt = video.publishedAt {
            return publishedAt.formatted(
                Date.FormatStyle(date: .long, time: .omitted).locale(.current)
            )
        }
        let relative = video.publishedTimeText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return relative?.isEmpty == false ? relative : nil
    }

    private var durationText: String? {
        let value = duration > 0 ? duration : (video.duration ?? 0)
        return value > 0 ? formatDuration(value) : nil
    }

    private var preferredInitialFocus: FocusedAction {
        trimmedDescription.isEmpty ? .playFromBeginning : .viewMore
    }

    var body: some View {
        TVPlayerInfoTabSurface(contentHeight: 390) {
            HStack(alignment: .top, spacing: 34) {
                channelAvatar

                VStack(alignment: .leading, spacing: 13) {
                    Text(video.title)
                        .font(.system(size: 35, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if !video.channelTitle.isEmpty {
                        Text(video.channelTitle)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    metadataRow

                    if !trimmedDescription.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 18) {
                                Text(String(localized: "Description", bundle: .module))
                                    .font(.system(size: 21, weight: .semibold))
                                    .foregroundStyle(.primary)

                                Button(action: onShowDescription) {
                                    Label("View More", systemImage: "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 18, weight: .semibold))
                                        .lineLimit(1)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .focused($focusedAction, equals: .viewMore)
                                .accessibilityHint("Opens the full video description")
                            }

                            Text(trimmedDescription)
                                .font(.system(size: 21, weight: .regular))
                                .foregroundStyle(.primary.opacity(0.86))
                                .lineSpacing(4)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 12) {
                    Button(action: onPlayFromBeginning) {
                        actionLabel("From Beginning", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .focused($focusedAction, equals: .playFromBeginning)
                    .accessibilityHint(String(localized: "Starts this video from the beginning", bundle: .module))

                    Button(action: onPlayNext) {
                        actionLabel("Next Video", systemImage: "forward.end.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!hasNextVideo)
                    .focused($focusedAction, equals: .playNext)

                    Button(action: onOpenChannel) {
                        actionLabel("Go to Channel", systemImage: "person.crop.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canOpenChannel)
                    .focused($focusedAction, equals: .openChannel)
                }
                .controlSize(.small)
                .frame(width: 280)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TVPlayerInfoTabLayout.contentHorizontalPadding)
            .padding(.vertical, TVPlayerInfoTabLayout.contentVerticalPadding)
            .focusSection()
            .defaultFocus($focusedAction, preferredInitialFocus, priority: .userInitiated)
            .task {
                // AVKit first focuses its private container when opening a custom
                // Info tab. Move that initial focus onto a real action after the
                // container has joined the focus hierarchy.
                await Task.yield()
                focusedAction = preferredInitialFocus
            }
        }
    }

    private var channelAvatar: some View {
        Group {
            if let avatarImage {
                Image(uiImage: avatarImage)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.12))
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.white.opacity(0.45))
                        .padding(28)
                }
            }
        }
        .frame(width: 124, height: 124)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var metadataRow: some View {
        HStack(spacing: 16) {
            if !video.formattedViewCount.isEmpty {
                infoMetric(video.formattedViewCount, systemImage: "eye.fill")
            }
            if let likeCount = likeCountText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !likeCount.isEmpty {
                infoMetric(likeCount, systemImage: "hand.thumbsup.fill")
                    .accessibilityLabel(String(localized: "Likes", bundle: .module) + ": " + likeCount)
            }
            if let publishedText {
                infoMetric(publishedText, systemImage: "calendar")
            }
            if let durationText {
                infoMetric(durationText, systemImage: "clock")
            }
            if let qualityLabel, !qualityLabel.isEmpty {
                infoMetric(qualityLabel, systemImage: "rectangle.badge.checkmark")
            }
        }
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func infoMetric(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
    }

    private func actionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 21, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(width: 252, height: 44)
    }
}
#endif
