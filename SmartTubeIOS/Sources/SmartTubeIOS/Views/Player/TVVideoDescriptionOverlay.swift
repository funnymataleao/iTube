#if os(tvOS)
import SwiftUI
import UIKit

struct TVVideoDescriptionOverlay: View {
    let title: String
    let channelTitle: String
    let description: String
    let onDismiss: @MainActor () -> Void

    @FocusState private var descriptionIsFocused: Bool
    @Namespace private var focusNamespace

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(String(localized: "Description", bundle: .module))
                        .font(.system(size: 30, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)

                    Text(title)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if !channelTitle.isEmpty {
                        Text(channelTitle)
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.vertical, 28)

                Divider()
                    .opacity(0.18)

                ScrollView(.vertical) {
                    Text(description.isEmpty ? String(localized: "No description available.", bundle: .module) : description)
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(description.isEmpty ? .secondary : .primary)
                        .lineSpacing(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 32)
                }
                .scrollIndicators(.visible)
                .focusable()
                .focused($descriptionIsFocused)
                .prefersDefaultFocus(in: focusNamespace)
                .accessibilityLabel(String(localized: "Description", bundle: .module))
            }
            .frame(width: 1240, height: 720)
            .background {
                TVPlayerLiquidGlassBackground(cornerRadius: 30)
            }
        }
        .focusScope(focusNamespace)
        .ignoresSafeArea()
        .onAppear {
            descriptionIsFocused = true
        }
        .onExitCommand(perform: onDismiss)
    }
}

@MainActor
final class TVVideoDescriptionHost: UIHostingController<TVVideoDescriptionOverlay> {
    var onHostDismissed: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onHostDismissed?()
        }
    }
}

#endif
