import SwiftUI

/// Weeknotes looks like a well-kept notebook: warm paper, ink, and one marmalade accent.
/// Update bodies are set in the system serif (New York) so they read like writing, not UI.
enum Theme {
    static let paper = Color(light: .init(red: 0.969, green: 0.953, blue: 0.918), dark: .init(red: 0.090, green: 0.082, blue: 0.075))
    static let card = Color(light: .init(red: 1.0, green: 0.996, blue: 0.984), dark: .init(red: 0.149, green: 0.137, blue: 0.125))
    static let ink = Color(light: .init(red: 0.122, green: 0.106, blue: 0.086), dark: .init(red: 0.949, green: 0.933, blue: 0.898))
    static let secondaryInk = Color(light: .init(red: 0.392, green: 0.361, blue: 0.322), dark: .init(red: 0.690, green: 0.663, blue: 0.620))
    static let hairline = Color(light: .init(red: 0.871, green: 0.847, blue: 0.800), dark: .init(red: 0.243, green: 0.227, blue: 0.208))
    static let accent = Color.accentColor
    static let unread = Color.accentColor

    static func body(_ size: CGFloat = 17) -> Font { .system(size: size, design: .serif) }
    static let bodyFont = Font.system(.body, design: .serif)
    static let titleFont = Font.system(.largeTitle, design: .serif).weight(.semibold)
    static let headingFont = Font.system(.title3, design: .serif).weight(.semibold)

    static let cornerRadius: CGFloat = 22
}

extension Color {
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.hairline.opacity(0.6), lineWidth: 0.5))
    }
}

extension View {
    func card(padding: CGFloat = 18) -> some View { modifier(CardBackground(padding: padding)) }

    /// The paper background behind every screen.
    func paperBackground() -> some View {
        background(Theme.paper.ignoresSafeArea())
    }
}
