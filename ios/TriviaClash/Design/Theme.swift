import SwiftUI
import UIKit

/// Trivia Clash visual identity: deep navy surfaces, one electric "volt" accent,
/// heavy expanded type, and colour used only where it carries meaning
/// (your answer, right/wrong, teams, the clock).
enum Theme {
    private static func dynamic(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    static let background = dynamic(0x0B1020, 0xF2F3F8)
    static let surface = dynamic(0x141B33, 0xFFFFFF)
    static let surfaceRaised = dynamic(0x1D2647, 0xE6E9F2)
    static let stroke = dynamic(0x2A3459, 0xD5D9E6)
    static let ink = dynamic(0xF2F4FF, 0x0E1430)
    static let inkMuted = dynamic(0x98A1C2, 0x535C7E)
    /// Signature accent. Used as a fill behind dark text in both appearances.
    static let volt = Color(UIColor(hex: 0xC6FF3D))
    /// Accent for text/icons that must stay readable on the current background.
    static let voltInk = dynamic(0xC6FF3D, 0x3D6A00)
    static let onVolt = Color(UIColor(hex: 0x0B1020))
    static let correct = dynamic(0x3DDC97, 0x0F8A55)
    static let wrong = dynamic(0xFF5A5F, 0xC9262C)
    static let warning = dynamic(0xFFB020, 0xA86800)

    static let teamColors: [Color] = [
        Color(UIColor(hex: 0xC6FF3D)), Color(UIColor(hex: 0xFF7A45)),
        Color(UIColor(hex: 0x3DB8FF)), Color(UIColor(hex: 0xC48BFF)),
    ]

    static let avatarColors: [Color] = ([
        0xC6FF3D, 0xFF7A45, 0x3DB8FF, 0xC48BFF, 0xFF5FA2, 0x3DDC97,
        0xFFD23D, 0x6C8BFF, 0xFF9E3D, 0x2EE6D6, 0xE0E5FF, 0xFF4F4F,
    ] as [UInt32]).map { Color(UIColor(hex: $0)) }

    static let avatarGlyphs = ["bolt.fill", "flame.fill", "drop.fill", "star.fill", "heart.fill", "leaf.fill",
                               "sun.max.fill", "moon.fill", "sparkle", "hare.fill", "crown.fill", "atom"]

    static func teamColor(_ index: Int?) -> Color {
        guard let index else { return inkMuted }
        return teamColors[index % teamColors.count]
    }

    static func avatarColor(_ index: Int) -> Color { avatarColors[abs(index) % avatarColors.count] }
    static func avatarGlyph(_ index: Int) -> String { avatarGlyphs[abs(index) % avatarGlyphs.count] }

    static let corner: CGFloat = 16
    static let gutter: CGFloat = 20
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Font {
    /// Display type: heavy, expanded, still scales with Dynamic Type.
    static func display(_ style: Font.TextStyle) -> Font {
        .system(style, design: .default).weight(.black).width(.expanded)
    }

    static func label(_ style: Font.TextStyle) -> Font {
        .system(style, design: .default).weight(.semibold)
    }

    static func numeric(_ style: Font.TextStyle) -> Font {
        .system(style, design: .rounded).weight(.heavy).monospacedDigit()
    }
}

extension View {
    /// Full-screen app background.
    func clashBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}
