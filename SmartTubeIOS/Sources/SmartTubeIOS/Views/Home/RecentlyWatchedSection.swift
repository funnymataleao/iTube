import SwiftUI
import SmartTubeIOSCore

#if os(tvOS)
/// Horizontal row of recently published videos (new content from subscribed channels).
/// Displays below the hero carousel, matching Apple TV YouTube's "Continuar a ver" / recent content section.
/// Supports infinite horizontal scrolling with lazy loading.
struct RecentlyWatchedSection: View {
    let videos: [Video]
    let onSelect: (Video) -> Void
    let loadMore: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 28

    private let cardWidth: CGFloat = 380
    private let cardHeight: CGFloat = 214 // 16:9 aspect ratio

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section title
            Text("Continuar a ver")
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 90)
                .accessibilityAddTraits(.isHeader)

            // Horizontal scrolling cards with infinite scroll
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                        RecentlyWatchedCard(video: video)
                            .frame(width: cardWidth, height: cardHeight)
                            .onTapGesture {
                                onSelect(video)
                            }
                            .onAppear {
                                // Trigger load more when approaching the end
                                if index == videos.count - 3 {
                                    loadMore()
                                }
                            }
                    }
                }
                .padding(.horizontal, 90)
            }
        }
        .padding(.vertical, 20)
    }
}

/// Individual card for recently published video with thumbnail, title, and metadata.
private struct RecentlyWatchedCard: View {
    let video: Video

    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .body) private var titleFontSize: CGFloat = 18
    @ScaledMetric(relativeTo: .caption) private var metadataFontSize: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail with progress bar
            GeometryReader { geometry in
                ZStack(alignment: .bottomLeading) {
                    // Thumbnail image
                    AsyncImage(url: thumbnailURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure, .empty:
                            Rectangle()
                                .fill(Color.secondary.opacity(0.2))
                        default:
                            Rectangle()
                                .fill(Color.secondary.opacity(0.2))
                                .overlay(ProgressView())
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()

                    // Subtle vignette for better text contrast
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    // Duration badge
                    if let duration = video.duration, duration > 0 {
                        durationBadge(formattedDuration(duration))
                            .padding(10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }


                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isFocused ? .white.opacity(0.6) : .clear,
                        lineWidth: 3
                    )
            }

            // Video title
            Text(video.title)
                .font(.system(size: titleFontSize, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .padding(.top, 8)
                .padding(.horizontal, 4)

            // Channel name
            Text(video.channelTitle)
                .font(.system(size: metadataFontSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 4)
        }
        .focusable()
        .focused($isFocused)
        .scaleEffect(isFocused && !reduceMotion ? 1.05 : 1.0)
        .shadow(
            color: isFocused ? .white.opacity(0.3) : .black.opacity(0.2),
            radius: isFocused ? 20 : 10,
            y: isFocused ? 8 : 5
        )
        .animation(.spring(response: 0.35, dampingFraction: 1.0), value: isFocused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(video.title), \(video.channelTitle)")
        .accessibilityHint("Play video")
    }

    // MARK: - Duration Badge

    @ViewBuilder
    private func durationBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: metadataFontSize, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                if #available(tvOS 26.0, *), !reduceTransparency {
                    Color.clear
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.75))
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }

    // MARK: - Helpers

    private var thumbnailURL: URL? {
        video.thumbnailURL ?? URL(string: "https://i.ytimg.com/vi/\(video.id)/hqdefault.jpg")
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
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

// MARK: - Preview

#if DEBUG
#Preview {
    RecentlyWatchedSection(
        videos: [
            Video(
                id: "1",
                title: "Costa do Mosquito - Trailer Oficial",
                channelTitle: "Apple TV Brasil",
                duration: 158,
                viewCount: 1_200_000,
                watchProgress: 0.35
            ),
            Video(
                id: "2",
                title: "Sequestro - Episódio 1",
                channelTitle: "Apple TV+",
                duration: 3420,
                viewCount: 850_000,
                watchProgress: 0.62
            ),
            Video(
                id: "3",
                title: "O Filme - Documentário Completo",
                channelTitle: "Formula 1",
                duration: 5280,
                viewCount: 2_100_000,
                watchProgress: 0.78
            ),
            Video(
                id: "4",
                title: "Down Cemetery Road - Trailer",
                channelTitle: "Paramount+",
                duration: 142,
                viewCount: 450_000,
                watchProgress: 0.15
            ),
            Video(
                id: "5",
                title: "Última Fronteira - Série Original",
                channelTitle: "HBO Max",
                duration: 2940,
                viewCount: 1_800_000,
                watchProgress: 0.89
            )
        ],
        onSelect: { _ in },
        loadMore: { }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
}
#endif
#endif
