import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private struct AnkiMinimalistModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var ankiMinimalistMode: Bool {
        get { self[AnkiMinimalistModeKey.self] }
        set { self[AnkiMinimalistModeKey.self] = newValue }
    }
}

private struct AnkiGlassModifier: ViewModifier {
    @Environment(\.ankiMinimalistMode) private var minimalistMode
    let tint: Color?
    let interactive: Bool
    let shape: AnyShape

    @ViewBuilder
    func body(content: Content) -> some View {
        if minimalistMode {
            let fill = tint ?? Color.white.opacity(0.06)
            content
                .background(fill, in: shape)
        } else if let tint {
            if interactive {
                content.glassEffect(.regular.tint(tint).interactive(), in: shape)
            } else {
                content.glassEffect(.regular.tint(tint), in: shape)
            }
        } else if interactive {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

private struct AnkiShadowModifier: ViewModifier {
    @Environment(\.ankiMinimalistMode) private var minimalistMode
    let color: Color
    let radius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if minimalistMode {
            content
        } else {
            content.shadow(color: color, radius: radius)
        }
    }
}

extension View {
    func ankiGlass<S: Shape>(tint: Color? = nil, interactive: Bool = false, in shape: S) -> some View {
        modifier(AnkiGlassModifier(tint: tint, interactive: interactive, shape: AnyShape(shape)))
    }

    func ankiShadow(color: Color, radius: CGFloat) -> some View {
        modifier(AnkiShadowModifier(color: color, radius: radius))
    }
}

enum AppTheme {
    static let deepTeal = Color(red: 0.02, green: 0.14, blue: 0.18)
    static let ink = Color(red: 0.03, green: 0.05, blue: 0.07)
    #if os(iOS)
    static let mist = Color(uiColor: .systemCyan)
    static let accent = Color(uiColor: .systemTeal)
    static let warn = Color(uiColor: .systemOrange)
    static let danger = Color(uiColor: .systemRed)
    static let good = Color(uiColor: .systemGreen)
    static let easy = Color(uiColor: .systemBlue)
    #else
    static let mist = Color(nsColor: .systemCyan)
    static let accent = Color(nsColor: .systemTeal)
    static let warn = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
    static let good = Color(nsColor: .systemGreen)
    static let easy = Color(nsColor: .systemBlue)
    #endif

    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText = Color.secondary.opacity(0.75)

    static let titleFont = Font.system(.largeTitle, design: .rounded).weight(.bold)
    static let deckFont = Font.system(.title3, design: .rounded).weight(.semibold)
}

struct AppBackground: View {
    @Environment(\.ankiMinimalistMode) private var minimalistMode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if minimalistMode {
                colorScheme == .dark
                    ? AppTheme.ink
                    : Color(red: 0.96, green: 0.97, blue: 0.98)
            } else if colorScheme == .light {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.96, green: 0.97, blue: 0.98),
                            Color.white,
                            Color(red: 0.92, green: 0.95, blue: 0.97)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    RadialGradient(
                        colors: [AppTheme.accent.opacity(0.08), .clear],
                        center: .topTrailing,
                        startRadius: 20,
                        endRadius: 420
                    )
                }
            } else {
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
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    func ankiSecondary() -> some View {
        foregroundStyle(AppTheme.secondaryText)
    }

    func ankiPrimary() -> some View {
        foregroundStyle(AppTheme.primaryText)
    }

    func glassField(cornerRadius: CGFloat = 14) -> some View {
        self
            .padding(12)
            .ankiGlass(tint: .white.opacity(0.08), interactive: true, in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}
