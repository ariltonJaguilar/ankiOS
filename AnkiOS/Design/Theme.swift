import SwiftUI

enum AppTheme {
    static let deepTeal = Color(red: 0.02, green: 0.14, blue: 0.18)
    static let ink = Color(red: 0.03, green: 0.05, blue: 0.07)
    static let mist = Color(red: 0.72, green: 0.90, blue: 0.94)
    static let accent = Color(red: 0.40, green: 0.94, blue: 0.88)
    static let warn = Color(red: 1.0, green: 0.84, blue: 0.45)
    /// Bright enough for dark glass backgrounds.
    static let danger = Color(red: 1.0, green: 0.58, blue: 0.60)
    static let good = Color(red: 0.50, green: 0.96, blue: 0.68)
    static let easy = Color(red: 0.60, green: 0.82, blue: 1.0)

    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.72)
    static let tertiaryText = Color.white.opacity(0.55)

    static let titleFont = Font.system(.largeTitle, design: .rounded).weight(.bold)
    static let deckFont = Font.system(.title3, design: .rounded).weight(.semibold)
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AppTheme.deepTeal,
                    AppTheme.ink,
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    AppTheme.accent.opacity(0.20),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 420
            )
            RadialGradient(
                colors: [
                    AppTheme.mist.opacity(0.12),
                    .clear
                ],
                center: .bottomLeading,
                startRadius: 10,
                endRadius: 380
            )
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Readable secondary text on dark glass (avoid system `.secondary` which goes muddy).
    func ankiSecondary() -> some View {
        foregroundStyle(AppTheme.secondaryText)
    }

    func ankiPrimary() -> some View {
        foregroundStyle(AppTheme.primaryText)
    }

    func glassField(cornerRadius: CGFloat = 14) -> some View {
        self
            .padding(12)
            .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: cornerRadius))
    }
}
