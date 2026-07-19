import SwiftUI

/// Slacker's brand system — "Calm Indigo". One place for color, type, and metrics so the
/// whole app stays consistent. Tweak here to restyle everything.
enum Brand {
    // MARK: Palette
    static let primary = Color(hex: 0x5B5BD6)        // indigo
    static let primaryDeep = Color(hex: 0x4A4AC4)
    static let missed = Color(hex: 0xF5A623)         // amber — missed follow-ups (someone's waiting)
    static let stale = Color(hex: 0xE5484D)          // rose — stale (getting old)
    static let mention = Color(hex: 0x2F9E9E)        // teal — direct mentions
    static let resolved = Color(hex: 0x30A46C)       // green — resolved / caught up
    static let ink = Color(hex: 0x1C1C28)

    /// The signature gradient (logo, hero surfaces).
    static let gradient = LinearGradient(
        colors: [Color(hex: 0x7C7CF0), Color(hex: 0x4A4AC4)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let tagline = "Cut the chatter with slacker"

    // MARK: Type
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // MARK: Metrics
    static let corner: CGFloat = 12
    static let cardPadding: CGFloat = 14
}

extension Color {
    /// Init from a 24-bit hex literal, e.g. `Color(hex: 0x5B5BD6)`.
    init(hex: UInt) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Brand styling for surfaced signal types.
extension ItemType {
    var brandColor: Color {
        switch self {
        case .missedFollowup: return Brand.missed
        case .stale: return Brand.stale
        case .mention: return Brand.mention
        }
    }

    var brandIcon: String {
        switch self {
        case .missedFollowup: return "questionmark.circle.fill"
        case .stale: return "hourglass"
        case .mention: return "at.circle.fill"
        }
    }

    var brandLabel: String {
        switch self {
        case .missedFollowup: return "Missed follow-up"
        case .stale: return "Stale"
        case .mention: return "Mention"
        }
    }

    var brandSectionTitle: String {
        switch self {
        case .missedFollowup: return "Missed follow-ups"
        case .stale: return "Stale"
        case .mention: return "Mentions"
        }
    }
}

/// A soft, consistent card background used across lists.
struct BrandCard: ViewModifier {
    var tint: Color = .secondary
    func body(content: Content) -> some View {
        content
            .padding(Brand.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: Brand.corner, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Brand.corner, style: .continuous)
                    .strokeBorder(tint.opacity(0.18))
            )
    }
}

extension View {
    func brandCard(tint: Color = .secondary) -> some View { modifier(BrandCard(tint: tint)) }
}
