import SwiftUI
import os

#if os(macOS)
import AppKit
typealias ThumbnailPlatformImage = NSImage
#else
import UIKit
typealias ThumbnailPlatformImage = UIImage
#endif

private let loaderLog = Logger(subsystem: "com.smarttube", category: "thumbnail-loader")

/// Reliable thumbnail loader with guaranteed sequential fallback.
/// Unlike AsyncImage, this loader ensures that HTTP 404 or other failures
/// automatically trigger the next candidate URL without leaving a gray placeholder.
@MainActor
final class ThumbnailImageLoader: ObservableObject {
    @Published var image: ThumbnailPlatformImage?
    @Published var isLoading = false
    @Published var currentCandidateIndex = 0

    private var candidates: [URL] = []
    private var videoId: String = ""
    private var loadTask: Task<Void, Never>?

    private static let cache = NSCache<NSString, ThumbnailPlatformImage>()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    func load(candidates: [URL], videoId: String) {
        // Cancel previous load
        loadTask?.cancel()

        guard !candidates.isEmpty else {
            loaderLog.warning("[ThumbnailLoader] No candidates for id=\(videoId)")
            self.image = nil
            self.isLoading = false
            return
        }

        self.candidates = candidates
        self.videoId = videoId
        self.currentCandidateIndex = 0
        self.isLoading = true

        loaderLog.notice("[ThumbnailLoader] START id=\(videoId) candidates=\(candidates.count)")

        loadTask = Task {
            await loadNextCandidate()
        }
    }

    func cancel() {
        loadTask?.cancel()
        isLoading = false
    }

    private func loadNextCandidate() async {
        guard currentCandidateIndex < candidates.count else {
            loaderLog.error("[ThumbnailLoader] EXHAUSTED id=\(self.videoId) tried=\(self.candidates.count)")
            await MainActor.run {
                self.image = nil
                self.isLoading = false
            }
            return
        }

        let url = candidates[currentCandidateIndex]
        let cacheKey = url.absoluteString as NSString

        // Check cache first
        if let cached = Self.cache.object(forKey: cacheKey) {
            loaderLog.info("[ThumbnailLoader] ✅ CACHE HIT id=\(self.videoId) idx=\(self.currentCandidateIndex)")
            await MainActor.run {
                self.image = cached
                self.isLoading = false
            }
            return
        }

        loaderLog.debug("[ThumbnailLoader] ⏳ REQUEST id=\(self.videoId) idx=\(self.currentCandidateIndex) url=\(url.absoluteString.suffix(80))")

        do {
            let (data, response) = try await Self.session.data(from: url)

            guard !Task.isCancelled else {
                loaderLog.debug("[ThumbnailLoader] CANCELLED id=\(self.videoId) idx=\(self.currentCandidateIndex)")
                return
            }

            // Check HTTP status
            if let httpResponse = response as? HTTPURLResponse {
                guard (200..<300).contains(httpResponse.statusCode) else {
                    loaderLog.warning("[ThumbnailLoader] ❌ HTTP \(httpResponse.statusCode) id=\(self.videoId) idx=\(self.currentCandidateIndex)")
                    await tryNextCandidate()
                    return
                }
            }

            // Check data size
            guard data.count > 1000 else {
                loaderLog.warning("[ThumbnailLoader] ❌ EMPTY DATA (\(data.count)b) id=\(self.videoId) idx=\(self.currentCandidateIndex)")
                await tryNextCandidate()
                return
            }

            // Decode image
            guard let decoded = ThumbnailPlatformImage(data: data) else {
                loaderLog.warning("[ThumbnailLoader] ❌ DECODE FAIL id=\(self.videoId) idx=\(self.currentCandidateIndex)")
                await tryNextCandidate()
                return
            }

            loaderLog.info("[ThumbnailLoader] ✅ SUCCESS id=\(self.videoId) idx=\(self.currentCandidateIndex) size=\(decoded.size.width)×\(decoded.size.height)")

            // Cache and display
            Self.cache.setObject(decoded, forKey: cacheKey)

            await MainActor.run {
                self.image = decoded
                self.isLoading = false
            }

        } catch {
            loaderLog.warning("[ThumbnailLoader] ❌ ERROR id=\(self.videoId) idx=\(self.currentCandidateIndex) error=\(error.localizedDescription)")
            await tryNextCandidate()
        }
    }

    private func tryNextCandidate() async {
        await MainActor.run {
            self.currentCandidateIndex += 1
        }

        guard currentCandidateIndex < candidates.count else {
            loaderLog.error("[ThumbnailLoader] 🚫 EXHAUSTED id=\(self.videoId) tried=\(self.candidates.count)")
            await MainActor.run {
                self.image = nil
                self.isLoading = false
            }
            return
        }

        loaderLog.info("[ThumbnailLoader] 🔄 RETRY id=\(self.videoId) nextIdx=\(self.currentCandidateIndex)")
        await loadNextCandidate()
    }
}
