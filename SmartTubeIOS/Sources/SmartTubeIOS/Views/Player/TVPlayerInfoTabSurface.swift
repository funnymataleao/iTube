#if os(tvOS)
import SwiftUI

enum TVPlayerLiquidGlassStyle {
    case regular
    case clear
}

enum TVPlayerInfoTabLayout {
    // AVKit uses the tallest custom info controller to position the shared tab
    // strip. Every tab must therefore report exactly the same outer height,
    // regardless of its current data or scroll position.
    static let preferredHeight: CGFloat = 500
    static let contentTopPadding: CGFloat = 12
    static let contentHorizontalPadding: CGFloat = 36
    static let contentVerticalPadding: CGFloat = 26
}

struct TVPlayerInfoTabContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, TVPlayerInfoTabLayout.contentTopPadding)
            .frame(
                maxWidth: .infinity,
                minHeight: TVPlayerInfoTabLayout.preferredHeight,
                maxHeight: TVPlayerInfoTabLayout.preferredHeight,
                alignment: .top
            )
    }
}

struct TVPlayerInfoTabSurface<Content: View>: View {
    let contentHeight: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        TVPlayerInfoTabContainer {
            content()
                .frame(
                    maxWidth: .infinity,
                    minHeight: contentHeight,
                    maxHeight: contentHeight,
                    alignment: .topLeading
                )
                .background {
                    TVPlayerLiquidGlassBackground(cornerRadius: 30)
                }
        }
    }
}

struct TVPlayerLiquidGlassBackground: View {
    let cornerRadius: CGFloat
    let interactive: Bool
    let style: TVPlayerLiquidGlassStyle
    let tint: Color
    let opaqueFallback: Color?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        cornerRadius: CGFloat,
        interactive: Bool = false,
        style: TVPlayerLiquidGlassStyle = .regular,
        tint: Color = Color.white.opacity(0.06),
        opaqueFallback: Color? = nil
    ) {
        self.cornerRadius = cornerRadius
        self.interactive = interactive
        self.style = style
        self.tint = tint
        self.opaqueFallback = opaqueFallback
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        panelBackground
    }

    @ViewBuilder
    private var panelBackground: some View {
        if reduceTransparency {
            shape.fill(
                opaqueFallback ?? Color.black.opacity(interactive ? 0.78 : 0.86)
            )
        } else if #available(tvOS 26.0, *) {
            switch (style, interactive) {
            case (.regular, true):
                Color.clear.glassEffect(.regular.tint(tint).interactive(), in: shape)
            case (.regular, false):
                Color.clear.glassEffect(.regular.tint(tint), in: shape)
            case (.clear, true):
                Color.clear.glassEffect(.clear.tint(tint).interactive(), in: shape)
            case (.clear, false):
                Color.clear.glassEffect(.clear.tint(tint), in: shape)
            }
        } else {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(tint)
            }
        }
    }
}
#endif
