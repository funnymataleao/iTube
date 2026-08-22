import Foundation
import SmartTubeIOSCore

@MainActor
@Observable
final class CommentsController {

    private(set) var comments: [Comment] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?
    private(set) var canLoadMore = false

    private let api: InnerTubeAPI
    private let logError: (String) -> Void
    private var loadedVideoId: String?
    private var nextToken: String?

    init(api: InnerTubeAPI, logError: @escaping (String) -> Void = { _ in }) {
        self.api = api
        self.logError = logError
    }

    func reset() {
        comments = []
        isLoading = false
        isLoadingMore = false
        errorMessage = nil
        canLoadMore = false
        loadedVideoId = nil
        nextToken = nil
    }

    func hasComments(for videoId: String) -> Bool {
        loadedVideoId == videoId && !comments.isEmpty
    }

    func load(videoId: String) {
        if loadedVideoId != videoId {
            reset()
            loadedVideoId = videoId
        }
        guard comments.isEmpty, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let page = try await api.fetchComments(videoId: videoId)
                guard loadedVideoId == videoId else { return }
                comments = page.comments
                nextToken = page.continuationToken
                canLoadMore = page.continuationToken != nil
            } catch {
                logError("fetchComments failed: \(String(describing: error))")
                errorMessage = String(localized: "Couldn't load comments. Try again.", bundle: .module)
            }
            isLoading = false
        }
    }

    func loadMoreIfNeeded(current comment: Comment) {
        guard comment.id == comments.last?.id,
              canLoadMore,
              let token = nextToken,
              let videoId = loadedVideoId,
              !isLoading,
              !isLoadingMore else { return }
        isLoadingMore = true
        Task {
            do {
                let page = try await api.fetchComments(videoId: videoId, continuationToken: token)
                guard loadedVideoId == videoId else { return }
                let existing = Set(comments.map(\.id))
                comments.append(contentsOf: page.comments.filter { !existing.contains($0.id) })
                nextToken = page.continuationToken
                canLoadMore = page.continuationToken != nil
            } catch {
                logError("fetchComments page failed: \(String(describing: error))")
                canLoadMore = false
            }
            isLoadingMore = false
        }
    }
}
