#if os(tvOS)
import SwiftUI
import SmartTubeIOSCore

struct TVCommentsInfoView: View {
    let commentsController: CommentsController
    let videoID: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TVPlayerInfoTabSurface(contentHeight: 440) {
            Group {
                if commentsController.isLoading && commentsController.comments.isEmpty {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = commentsController.errorMessage,
                          commentsController.comments.isEmpty {
                    Text(errorMessage)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(48)
                } else if commentsController.comments.isEmpty {
                    Text("No comments")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(commentsController.comments) { comment in
                                TVCommentRow(comment: comment, reduceMotion: reduceMotion)
                                    .id(comment.id)
                                    .onAppear {
                                        commentsController.loadMoreIfNeeded(current: comment)
                                    }
                            }

                            if commentsController.isLoadingMore {
                                ProgressView()
                                    .controlSize(.regular)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                        }
                        .padding(.horizontal, TVPlayerInfoTabLayout.contentHorizontalPadding)
                        .padding(.vertical, TVPlayerInfoTabLayout.contentVerticalPadding)
                    }
                    .scrollIndicators(.hidden)
                    .focusSection()
                }
            }
        }
        .task(id: videoID) {
            guard !videoID.isEmpty else { return }
            commentsController.load(videoId: videoID)
        }
    }
}

private struct TVCommentRow: View {
    let comment: Comment
    let reduceMotion: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncImage(url: comment.authorAvatarURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Circle().fill(Color.white.opacity(0.12))
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(comment.author)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if !comment.publishedTime.isEmpty {
                        Text(comment.publishedTime)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(comment.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                if !comment.likeCount.isEmpty {
                    Label(comment.likeCount, systemImage: "hand.thumbsup")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background {
            if isFocused {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.12))
            }
        }
        .scaleEffect(reduceMotion ? 1 : (isFocused ? 1.015 : 1))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
        .focusable()
    }
}
#endif
