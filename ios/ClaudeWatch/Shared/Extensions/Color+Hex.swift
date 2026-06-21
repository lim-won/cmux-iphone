import SwiftUI

extension Color {

    /// Creates a `Color` from a hex string.
    ///
    /// Supported formats: `"#RRGGBB"`, `"RRGGBB"`, `"#RRGGBBAA"`, `"RRGGBBAA"`.
    /// Returns `Color.clear` for malformed input.
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&rgb)

        let r, g, b, a: Double
        switch sanitized.count {
        case 6: // RRGGBB
            r = Double((rgb >> 16) & 0xFF) / 255.0
            g = Double((rgb >> 8) & 0xFF) / 255.0
            b = Double(rgb & 0xFF) / 255.0
            a = 1.0
        case 8: // RRGGBBAA
            r = Double((rgb >> 24) & 0xFF) / 255.0
            g = Double((rgb >> 16) & 0xFF) / 255.0
            b = Double((rgb >> 8) & 0xFF) / 255.0
            a = Double(rgb & 0xFF) / 255.0
        default:
            r = 0; g = 0; b = 0; a = 0
        }

        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    // MARK: - Cmux iPhone design system
    //
    // Palette (from design/Cmux iPhone.html):
    //   background #0A0A0B · surface #151517 · accent #EE7E38 ·
    //   approval #E8A735 · running #54C98A · deny #E5484D · text #F4F3F1
    // Rule: one color per state, used sparingly; hairline borders, not heavy strokes;
    // monospace only for code/paths; mascot only for human moments.

    /// App background (near-black): #0A0A0B
    static let appBackground = Color(hex: "0A0A0B")

    /// Primary accent orange: #EE7E38
    static let claudeOrange = Color(hex: "EE7E38")

    /// Approval / amber warning: #E8A735
    static let claudeAmber = Color(hex: "E8A735")

    /// Running / success green: #54C98A
    static let statusGreen = Color(hex: "54C98A")

    /// Deny / error red: #E5484D
    static let denyRed = Color(hex: "E5484D")

    /// Primary text (off-white): #F4F3F1
    static let textPrimary = Color(hex: "F4F3F1")

    /// Secondary / subtle text: #6E6E73
    static let subtleText = Color(hex: "6E6E73")

    /// Tertiary muted text: #86868B
    static let mutedText = Color(hex: "86868B")

    /// Card / surface background: #151517
    static let cardBackground = Color(hex: "151517")

    /// Elevated surface (nested rows): #1C1C1E
    static let surfaceElevated = Color(hex: "1C1C1E")

    /// Hairline border — thin white line, ~6% opacity.
    static let hairline = Color.white.opacity(0.06)

    /// Field border (subtle): white ~10%.
    static let fieldBorder = Color.white.opacity(0.10)

    /// Connected pill background: #1a2233
    static let connectedPillBackground = Color(hex: "1a2233")
}
