import SwiftUI
import SmartTubeIOSCore
import AVKit

#if os(tvOS)
/// Apple TV-style hero video carousel with liquid glass effects, autoplay, and swipe navigation.
/// Features:
/// - Full-screen video preview with autoplay after hook duration (~60 seconds)
/// - Liquid glass translucent materials following Apple's design guidelines
/// - Swipe navigation between videos and action buttons
/// - Page indicator dots
/// - Metadata overlay with channel info, duration, and upload date
struct AppleTVHeroView: View {
    let videos: [Video]
    let onVideoSelect: (Video) -> Void
    
    @State private var currentIndex: Int = 0
    @State private var focusedButton: HeroButton = .play
    @State private var isVideoPlaying: Bool = false
    @State private var autoplayTimer: Timer?
    @State private var player: AVPlayer?
    @State private var thumbnailOpacity: Double = 1.0
    @FocusState private var isHeroFocused: Bool
    
    @Environment(AuthService.self) private var authService
    @Environment(\.innerTubeAPI) private var api
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    
    // Scaled metrics for accessibility
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 56
    @ScaledMetric(relativeTo: .title2) private var channelSize: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var metadataSize: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var descriptionSize: CGFloat = 18
    
    private let hookDuration: TimeInterval = 60.0 // Average YouTube hook duration
    
    private enum HeroButton: CaseIterable {
        case play
        case info
        case next
        
        var iconName: String {
            switch self {
            case .play: return "play.fill"
            case .info: return "info.circle.fill"
            case .next: return "chevron.right.circle.fill"
            }
        }
        
        var label: String {
            switch self {
            case .play: return "Play"
            case .info: return "Info"
            case .next: return "Next"
            }
        }
    }
    
    private var currentVideo: Video {
        videos.isEmpty ? Video(id: "", title: "", channelTitle: "") : videos[currentIndex]
    }
    
    var body: some View {
        ZStack {
            // Layer 1: Full-screen video/thumbnail - fills entire screen
            videoLayer
            
            // Layer 2: Bottom gradient for text readability
            VStack {
                Spacer()
                LinearGradient(
                    colors: [.clear, .black.opacity(0.6), .black.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 500)
            }
            
            // Layer 3: Metadata + buttons at bottom left
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                
                metadataSection
                    .padding(.horizontal, 90)
                    .padding(.bottom, 80)
            }
            
            // Layer 4: Page indicator dots (centered at bottom)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    pageIndicator
                    Spacer()
                }
                .padding(.bottom, 200)
            }
        }
        .ignoresSafeArea()
        .focusable()
        .focused($isHeroFocused)
        .onMoveCommand { direction in
            handleSwipe(direction)
        }
        .onAppear {
            isHeroFocused = true
            startAutoplayTimer()
        }
        .onDisappear {
            stopAutoplayTimer()
            stopVideo()
        }
        .onChange(of: currentIndex) { _, _ in
            resetVideoState()
            startAutoplayTimer()
        }
    }
    
    // MARK: - Video Layer
    
    @ViewBuilder
    private var videoLayer: some View {
        ZStack {
            if isVideoPlaying, let player = player {
                VideoPlayer(player: player)
                    .disabled(true)
                    .ignoresSafeArea()
            } else {
                // Use maxresdefault for highest quality thumbnail (1280x720)
                let thumbnailURL = URL(string: "https://i.ytimg.com/vi/\(currentVideo.id)/maxresdefault.jpg")
                AsyncImage(url: thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .ignoresSafeArea()
                    case .failure:
                        // Fallback to hq720 if maxres not available
                        AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(currentVideo.id)/hq720.jpg")) { fallbackPhase in
                            switch fallbackPhase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .ignoresSafeArea()
                            default:
                                Color.black
                                    .ignoresSafeArea()
                            }
                        }
                    case .empty:
                        Color.black
                            .ignoresSafeArea()
                            .overlay(ProgressView())
                    default:
                        Color.black
                            .ignoresSafeArea()
                            .overlay(ProgressView())
                    }
                }
            }
        }
    }
    
    // MARK: - Metadata Section with Liquid Glass
    
    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Large title
            Text(currentVideo.title)
                .font(.system(size: titleSize, weight: .bold))
                .tracking(-1.0)
                .foregroundStyle(.white)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
            
            // Channel info row
            HStack(spacing: 16) {
                // Channel icon placeholder
                Circle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Text(String(currentVideo.channelTitle.prefix(1)).uppercased())
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                    )
                
                Text(currentVideo.channelTitle)
                    .font(.system(size: channelSize, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                
                Spacer()
                
                // Duration badge with liquid glass
                if let duration = currentVideo.duration, duration > 0 {
                    liquidGlassBadge(formattedDuration(duration))
                }
            }
            
            // Metadata: views, upload date
            Text(metadataText)
                .font(.system(size: metadataSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            
            // Brief description
            if let description = currentVideo.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: descriptionSize))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .onTapGesture {
                        // TODO: Show full description popup
                    }
            }
            
            // Action buttons row with swipe navigation
            actionButtonsRow
                .padding(.top, 24)
        }
    }
    
    // MARK: - Action Buttons with Focus Navigation
    
    private var actionButtonsRow: some View {
        HStack(spacing: 20) {
            ForEach(HeroButton.allCases, id: \.self) { button in
                heroButton(button)
            }
        }
    }
    
    private func heroButton(_ button: HeroButton) -> some View {
        let isFocused = focusedButton == button
        let isPlayButton = button == .play
        
        return Button(action: {
            handleButtonAction(button)
        }) {
            HStack(spacing: 12) {
                Image(systemName: button.iconName)
                    .font(.system(size: isPlayButton ? 28 : 24, weight: .semibold))
                
                if isPlayButton {
                    Text(button.label)
                        .font(.system(size: 22, weight: .semibold))
                }
            }
            .foregroundStyle(isPlayButton ? .black : .white)
            .padding(.horizontal, isPlayButton ? 40 : 20)
            .padding(.vertical, 16)
            .background(
                liquidGlassButtonBackground(isPlayButton: isPlayButton, isFocused: isFocused)
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(
                        isFocused ? .white.opacity(0.6) : .white.opacity(0.2),
                        lineWidth: isFocused ? 3 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isFocused && !reduceMotion ? 1.08 : 1.0)
        .shadow(color: isFocused ? .white.opacity(0.4) : .black.opacity(0.3), radius: isFocused ? 20 : 10)
        .animation(.spring(response: 0.35, dampingFraction: 1.0), value: isFocused)
    }
    
    @ViewBuilder
    private func liquidGlassButtonBackground(isPlayButton: Bool, isFocused: Bool) -> some View {
        if isPlayButton {
            // Play button: solid white with slight transparency when focused
            Color.white.opacity(isFocused ? 0.95 : 0.9)
        } else {
            // Other buttons: liquid glass effect
            if #available(tvOS 26.0, *), !reduceTransparency {
                Color.clear
                    .background(.ultraThinMaterial, in: Capsule())
            } else {
                Color.white.opacity(0.15)
            }
        }
    }
    
    // MARK: - Page Indicator
    
    private var pageIndicator: some View {
        HStack(spacing: 10) {
            ForEach(0..<min(videos.count, 10), id: \.self) { index in
                Circle()
                    .fill(index == currentIndex ? Color.white : Color.white.opacity(0.4))
                    .frame(width: index == currentIndex ? 12 : 8, height: index == currentIndex ? 12 : 8)
                    .animation(.spring(response: 0.3, dampingFraction: 1.0), value: currentIndex)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(liquidGlassMaterial)
        .clipShape(Capsule())
    }
    
    // MARK: - Liquid Glass Materials
    
    @ViewBuilder
    private var liquidGlassMaterial: some View {
        if #available(tvOS 26.0, *), !reduceTransparency {
            Color.clear
                .background(.ultraThinMaterial)
        } else {
            Color.black.opacity(0.5)
        }
    }
    
    @ViewBuilder
    private func liquidGlassBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: metadataSize, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background {
                if #available(tvOS 26.0, *), !reduceTransparency {
                    Color.clear
                        .background(.regularMaterial, in: Capsule())
                } else {
                    Color.black.opacity(0.7)
                        .clipShape(Capsule())
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }
    
    // MARK: - Swipe Navigation
    
    private func handleSwipe(_ direction: MoveCommandDirection) {
        switch direction {
        case .left:
            if focusedButton == .play {
                // Already at first button, do nothing
            } else if let currentIndex = HeroButton.allCases.firstIndex(of: focusedButton),
                      currentIndex > 0 {
                focusedButton = HeroButton.allCases[currentIndex - 1]
            }
            
        case .right:
            if focusedButton == .next {
                // Reached last button, swipe to next video
                moveToNextVideo()
            } else if let currentIndex = HeroButton.allCases.firstIndex(of: focusedButton),
                      currentIndex < HeroButton.allCases.count - 1 {
                focusedButton = HeroButton.allCases[currentIndex + 1]
            }
            
        case .up:
            // Could navigate to top navbar if needed
            break
            
        case .down:
            // Could navigate to "Recently Watched" section
            break
            
        @unknown default:
            break
        }
    }
    
    private func moveToNextVideo() {
        guard !videos.isEmpty else { return }
        currentIndex = (currentIndex + 1) % videos.count
        focusedButton = .play // Reset to play button
    }
    
    private func moveToPreviousVideo() {
        guard !videos.isEmpty else { return }
        currentIndex = (currentIndex - 1 + videos.count) % videos.count
        focusedButton = .play
    }
    
    // MARK: - Button Actions
    
    private func handleButtonAction(_ button: HeroButton) {
        switch button {
        case .play:
            onVideoSelect(currentVideo)
            
        case .info:
            // TODO: Show info popup with full description
            break
            
        case .next:
            moveToNextVideo()
        }
    }
    
    // MARK: - Autoplay Logic
    
    private func startAutoplayTimer() {
        stopAutoplayTimer()
        
        autoplayTimer = Timer.scheduledTimer(withTimeInterval: hookDuration, repeats: false) { _ in
            Task { @MainActor in
                await self.startVideoPreview()
            }
        }
    }
    
    private func stopAutoplayTimer() {
        autoplayTimer?.invalidate()
        autoplayTimer = nil
    }
    
    private func startVideoPreview() async {
        // Try to get HLS URL from cache
        if let cachedURL = await VideoPreloadCache.shared.cachedWKHLSURL(for: currentVideo.id) {
            await MainActor.run {
                let newPlayer = AVPlayer(url: cachedURL)
                newPlayer.isMuted = true
                self.player = newPlayer
                self.isVideoPlaying = true
                newPlayer.play()
            }
        }
        // If not cached, autoplay won't work until video is prefetched
        // This is expected behavior - autoplay requires preloaded content
    }
    
    private func stopVideo() {
        player?.pause()
        player = nil
        isVideoPlaying = false
    }
    
    private func resetVideoState() {
        stopVideo()
    }
    
    // MARK: - Helpers
    
    private var metadataText: String {
        var parts: [String] = []
        
        if let viewCount = currentVideo.viewCount, viewCount > 0 {
            parts.append(formatViewCount(viewCount))
        }
        
        if let publishedAt = currentVideo.publishedAt {
            parts.append(timeAgo(from: publishedAt))
        } else if let publishedText = currentVideo.publishedTimeText {
            parts.append(publishedText)
        }
        
        return parts.joined(separator: " • ")
    }
    
    private func formatViewCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000.0
            return String(format: "%.1fM views", millions)
        } else if count >= 1_000 {
            let thousands = Double(count) / 1_000.0
            return String(format: "%.1fK views", thousands)
        } else {
            return "\(count) views"
        }
    }
    
    private func timeAgo(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        let days = Int(interval / 86400)
        
        if days == 0 {
            return "Today"
        } else if days == 1 {
            return "1 day ago"
        } else if days < 7 {
            return "\(days) days ago"
        } else if days < 30 {
            let weeks = days / 7
            return weeks == 1 ? "1 week ago" : "\(weeks) weeks ago"
        } else if days < 365 {
            let months = days / 30
            return months == 1 ? "1 month ago" : "\(months) months ago"
        } else {
            let years = days / 365
            return years == 1 ? "1 year ago" : "\(years) years ago"
        }
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
    AppleTVHeroView(
        videos: [
            Video(
                id: "dQw4w9WgXcQ",
                title: "Rick Astley - Never Gonna Give You Up (Official Video)",
                channelTitle: "Rick Astley",
                description: "The official video for Never Gonna Give You Up by Rick Astley. Taken from the album Whenever You Need Somebody",
                duration: 213,
                viewCount: 1_400_000_000,
                publishedTimeText: "16 years ago"
            ),
            Video(
                id: "jNQXAC9IVRw",
                title: "Me at the zoo",
                channelTitle: "jawed",
                description: "The first video on YouTube. Recorded on April 23, 2005.",
                duration: 19,
                viewCount: 250_000_000,
                publishedTimeText: "18 years ago"
            )
        ],
        onVideoSelect: { _ in }
    )
}
#endif
#endif
