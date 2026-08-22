#if os(tvOS)
import SwiftUI
import SmartTubeIOSCore

struct TVChaptersInfoView: View {
    let chapters: [Chapter]
    let currentTime: TimeInterval
    let onSelectChapter: @MainActor (Chapter) -> Void

    @FocusState private var focusedChapterID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TVPlayerInfoTabContainer {
            if !chapters.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 34) {
                            ForEach(chapters) { chapter in
                                let isCurrent = chapter.id == currentChapterID

                                TVChapterCard(
                                    chapter: chapter,
                                    isCurrent: isCurrent,
                                    isFocused: focusedChapterID == chapter.id
                                )
                                .id(chapter.id)
                                .focusable(interactions: .activate)
                                .focusEffectDisabled()
                                .onTapGesture {
                                    onSelectChapter(chapter)
                                }
                                .focused($focusedChapterID, equals: chapter.id)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(chapter.title)
                                .accessibilityValue(accessibilityValue(for: chapter, isCurrent: isCurrent))
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                                .accessibilityAction {
                                    onSelectChapter(chapter)
                                }
                            }
                        }
                        .padding(.horizontal, TVPlayerInfoTabLayout.contentHorizontalPadding)
                        // The shared tab container already owns the top gap.
                        // Keep only the trailing breathing room for card focus/shadows.
                        .padding(.bottom, TVPlayerInfoTabLayout.contentVerticalPadding)
                    }
                    .scrollClipDisabled()
                    .focusEffectDisabled()
                    .scrollIndicators(.hidden)
                    .focusSection()
                    .defaultFocus(
                        $focusedChapterID,
                        currentChapterID ?? chapters.first?.id,
                        priority: .userInitiated
                    )
                    .onAppear {
                        scrollToPreferredChapter(using: proxy)
                    }
                    .onChange(of: currentChapterID) { _, _ in
                        guard focusedChapterID == nil else { return }
                        scrollToPreferredChapter(using: proxy)
                    }
                    .onChange(of: focusedChapterID) { _, chapterID in
                        guard let chapterID else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            proxy.scrollTo(chapterID, anchor: .center)
                        }
                    }
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
                }
            } else {
                Text("No chapters", bundle: .module)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var currentChapterID: UUID? {
        chapters.last(where: { $0.startTime <= currentTime })?.id
    }

    private func scrollToPreferredChapter(using proxy: ScrollViewProxy) {
        guard let chapterID = currentChapterID ?? chapters.first?.id else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(chapterID, anchor: .center)
        }
    }

    private func accessibilityValue(for chapter: Chapter, isCurrent: Bool) -> String {
        let startTime = formatDuration(chapter.startTime)
        guard isCurrent else { return startTime }
        return "\(String(localized: "Playing", bundle: .module)), \(startTime)"
    }
}

private struct TVChapterCard: View {
    let chapter: Chapter
    let isCurrent: Bool
    let isFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focusSweepAngle = -90.0
    @State private var artworkTone: VideoCardTone = .fallback

    private let cardWidth: CGFloat = 360
    private let cornerRadius: CGFloat = 24
    private let badgeForeground = Color(red: 0.035, green: 0.10, blue: 0.045)
    private let playingGradientLeading = Color(red: 0.32, green: 0.88, blue: 0.30)
    private let playingGradientTrailing = Color(red: 0.94, green: 0.91, blue: 0.24)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AsyncImage(url: chapter.thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    ZStack {
                        Color.black.opacity(0.22)
                        Image(systemName: "film")
                            .font(.system(size: 37))
                            .foregroundStyle(Color.white.opacity(0.58))
                    }
                }
            }
            .frame(width: cardWidth, height: 202)
            .background(Color.black.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .topLeading) {
                if isCurrent {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Playing", bundle: .module)
                    }
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(badgeForeground)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        playingGradientLeading,
                                        playingGradientTrailing,
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    }
                    .padding(12)
                    .accessibilityHidden(true)
                }
            }

            TVChapterMarqueeTitle(
                text: chapter.title,
                isActive: isFocused && !reduceMotion
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 34)

            Text(formatDuration(chapter.startTime))
                .font(.system(size: 23, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.68))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: cardWidth, alignment: .leading)
        .padding(17)
        .background {
            // Use the exact same material and tint as Info and Comments.
            TVPlayerLiquidGlassBackground(cornerRadius: cornerRadius)
            .shadow(
                color: .black.opacity(isFocused ? 0.48 : 0.22),
                radius: isFocused ? 24 : 12,
                x: 0,
                y: isFocused ? 12 : 7
            )
        }
        .overlay {
            chapterFocusBorder
        }
        .contentShape(cardShape)
        .onAppear {
            if isFocused {
                updateFocusSweep(isFocused: true)
            }
        }
        .onChange(of: isFocused) { _, newValue in
            updateFocusSweep(isFocused: newValue)
        }
        .task(id: chapter.thumbnailURL) {
            guard let thumbnailURL = chapter.thumbnailURL else {
                artworkTone = .fallback
                return
            }
            artworkTone = await VideoCardArtworkCache.shared.tone(for: thumbnailURL)
        }
        .scaleEffect(isFocused && !reduceMotion ? 1.045 : 1)
        .animation(
            reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 1),
            value: isFocused
        )
        .zIndex(isFocused ? 1 : 0)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var chapterFocusBorder: some View {
        ZStack {
            cardShape.strokeBorder(
                LinearGradient(
                    colors: [
                        artworkTone.focusGlow.opacity(isFocused ? 0.54 : 0.13),
                        artworkTone.color.opacity(isFocused ? 0.30 : 0.06),
                        artworkTone.focusGlow.opacity(isFocused ? 0.44 : 0.09),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: isFocused ? 1.25 : 0.75
            )

            if isFocused && !reduceMotion {
                cardShape.strokeBorder(
                    AngularGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 0.50),
                            .init(color: artworkTone.focusGlow.opacity(0.18), location: 0.62),
                            .init(color: artworkTone.focusGlow.opacity(0.94), location: 0.74),
                            .init(color: artworkTone.focusGlow.opacity(0.22), location: 0.86),
                            .init(color: .clear, location: 1),
                        ],
                        center: .center,
                        angle: .degrees(focusSweepAngle)
                    ),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
                .shadow(color: artworkTone.focusGlow.opacity(0.38), radius: 3.5)
            }
        }
    }

    private func updateFocusSweep(isFocused: Bool) {
        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            focusSweepAngle = -90
        }

        guard isFocused, !reduceMotion else { return }
        Task { @MainActor in
            await Task.yield()
            guard self.isFocused else { return }
            withAnimation(.linear(duration: 0.9)) {
                focusSweepAngle = 270
            }
        }
    }
}

private struct TVChapterMarqueeTitle: View {
    let text: String
    let isActive: Bool

    @State private var textWidth: CGFloat = 0
    @State private var animationStart = Date.now

    private let font = Font.system(size: 28, weight: .semibold)
    private let gap: CGFloat = 52
    private let initialPause: TimeInterval = 0.8
    private let pointsPerSecond: CGFloat = 32

    var body: some View {
        GeometryReader { proxy in
            let shouldScroll = isActive && textWidth > proxy.size.width + 1

            ZStack(alignment: .leading) {
                if shouldScroll {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                        HStack(spacing: gap) {
                            marqueeText
                            marqueeText
                        }
                        .offset(
                            x: marqueeOffset(
                                at: context.date,
                                distance: textWidth + gap
                            )
                        )
                    }
                } else {
                    Text(text)
                        .font(font)
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .leading
            )
            .clipped()
            .background(alignment: .leading) {
                marqueeText
                    .background {
                        GeometryReader { textProxy in
                            Color.clear.preference(
                                key: TVChapterTitleWidthKey.self,
                                value: textProxy.size.width
                            )
                        }
                    }
                    .hidden()
            }
            .onChange(of: shouldScroll) { _, active in
                if active {
                    animationStart = .now
                }
            }
            .onChange(of: proxy.size.width) { _, width in
                if width > 0 {
                    animationStart = .now
                }
            }
        }
        .onPreferenceChange(TVChapterTitleWidthKey.self) { width in
            textWidth = width
            animationStart = .now
        }
        .onChange(of: isActive) { _, active in
            if active {
                animationStart = .now
            }
        }
        .onChange(of: text) { _, _ in
            animationStart = .now
        }
    }

    private var marqueeText: some View {
        Text(text)
            .font(font)
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func marqueeOffset(at date: Date, distance: CGFloat) -> CGFloat {
        let elapsed = date.timeIntervalSince(animationStart) - initialPause
        guard elapsed > 0, distance > 0 else { return 0 }

        let duration = max(4, Double(distance / pointsPerSecond))
        let progress = elapsed.truncatingRemainder(dividingBy: duration) / duration
        return -distance * CGFloat(progress)
    }
}

private struct TVChapterTitleWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif
