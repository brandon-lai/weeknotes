import SwiftUI

/// Liquid Glass on iOS 26, the closest system look on iOS 18. Views use these instead of the
/// iOS 26 APIs directly, so every screen runs on both.
extension View {
    /// `.buttonStyle(.glass)` on iOS 26, bordered on iOS 18.
    @ViewBuilder
    func glassButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// `.buttonStyle(.glassProminent)` on iOS 26, bordered-prominent on iOS 18.
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// A glass background in `shape` on iOS 26; a material with a hairline edge on iOS 18.
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            let glass: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            glassEffect(interactive ? glass.interactive() : glass, in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tint { shape.fill(tint) }
                }
                .overlay(shape.stroke(Theme.hairline.opacity(0.8), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            }
        }
    }

    /// The tab bar shrinks while scrolling on iOS 26; iOS 18 has no such behavior.
    @ViewBuilder
    func minimizeTabBarOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

/// `GlassEffectContainer` on iOS 26 (neighboring glass shapes blend); a plain container on iOS 18.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
