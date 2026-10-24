import SwiftUI

struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 20
    var tint: Color = .white.opacity(0.07)
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ankiGlass(tint: tint, interactive: true, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AppTheme.primaryText.opacity(0.10), lineWidth: 1)
            }
    }
}

/// Liquid Glass button — tint wash stays translucent so material reads as glass.
struct GlassButtonStyle: ButtonStyle {
    var tint: Color = AppTheme.accent
    var prominent: Bool = true
    /// 0…1 strength of the color wash (lower = more glass).
    var tintStrength: Double = 0.38
    /// Stretch to available width for equal stacked CTAs.
    var expands: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(prominent ? .headline.weight(.semibold) : .subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.primaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: expands ? .infinity : nil)
            .padding(.horizontal, prominent ? 20 : 14)
            .padding(.vertical, prominent ? 14 : 8)
            .ankiGlass(tint: tint.opacity(tintStrength), interactive: true, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct GlassChipButtonStyle: ButtonStyle {
    var tint: Color = .white.opacity(0.14)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .ankiGlass(tint: tint, interactive: true, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct GlassIconButtonStyle: ButtonStyle {
    var tint: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 36, height: 36)
            .ankiGlass(tint: tint.opacity(0.14), interactive: true, in: Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

struct CountChip: View {
    let label: LocalizedStringKey
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .ankiShadow(color: color.opacity(0.7), radius: 3)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(count)")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(color)
                .ankiShadow(color: color.opacity(0.5), radius: 4)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(color.opacity(0.12), in: .capsule)
    }
}

/// Compact colored count for progress bars / deck rows.
struct CountDigit: View {
    let value: Int
    let color: Color

    var body: some View {
        Text("\(value)")
            .font(.subheadline.monospacedDigit().weight(.bold))
            .foregroundStyle(color)
            .ankiShadow(color: color.opacity(0.55), radius: 5)
            .frame(minWidth: 28, alignment: .trailing)
    }
}

struct EmptyStateView: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 88, height: 88)
                .background(AppTheme.accent.opacity(0.14), in: .circle)
            Text(title)
                .font(AppTheme.deckFont)
                .foregroundStyle(AppTheme.primaryText)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .ankiGlass(tint: .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(AppTheme.primaryText.opacity(0.12), lineWidth: 1)
        }
        .padding()
    }
}

struct GlassListRowBackground: View {
    @Environment(\.ankiMinimalistMode) private var minimalistMode
    var selected: Bool = false
    var tint: Color?

    private var resolvedTint: Color {
        tint ?? AppTheme.primaryText
    }

    var body: some View {
        Group {
            if minimalistMode {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(resolvedTint.opacity(selected ? 0.20 : 0.09))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(resolvedTint.opacity(selected ? 0.30 : 0.16), lineWidth: 1)
                    }
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(resolvedTint.opacity(selected ? 0.16 : 0.04))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(resolvedTint.opacity(selected ? 0.30 : 0.08), lineWidth: 1)
                    }
            }
        }
        .padding(.vertical, 2)
    }
}

/// One Liquid Glass row: label on the left, its control on the right.
struct GlassOptionRow<Trailing: View>: View {
    let title: Text
    let trailing: Trailing

    init(title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(title)
        self.trailing = trailing()
    }

    init(verbatimTitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(verbatim: verbatimTitle)
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            title
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            trailing
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                .clipped()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .ankiGlass(tint: .white.opacity(0.06), interactive: true, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AppTheme.primaryText.opacity(0.10), lineWidth: 1)
        }
    }
}

/// Menu whose selected value stays on one line and truncates inside the row.
struct GlassChoiceMenu<ID: Hashable>: View {
    @Binding var selection: ID
    let choices: [GlassChoice<ID>]
    let accessibilityPrefix: String?

    init(
        selection: Binding<ID>,
        choices: [GlassChoice<ID>],
        accessibilityPrefix: String? = nil
    ) {
        _selection = selection
        self.choices = choices
        self.accessibilityPrefix = accessibilityPrefix
    }

    private var selectedTitle: String {
        choices.first { $0.id == selection }?.title ?? "—"
    }

    var body: some View {
        Picker(selection: $selection) {
            ForEach(choices) { choice in
                if let accessibilityPrefix {
                    Text(choice.title)
                        .tag(choice.id)
                        .accessibilityIdentifier("\(accessibilityPrefix).\(choice.title)")
                } else {
                    Text(choice.title)
                        .tag(choice.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.trailing)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(AppTheme.primaryText)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .pickerStyle(.menu)
        .menuIndicator(.hidden)
        .buttonStyle(GlassChipButtonStyle())
    }
}

struct GlassChoice<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
}

struct GlassFormSection<Content: View>: View {
    let title: Text
    let content: Content

    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title
                .font(.headline.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
                .padding(.leading, 4)
            content
        }
    }
}

/// Stacked content (slider, multiline field) inside its own glass block.
struct GlassInset<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ankiGlass(tint: .white.opacity(0.06), interactive: true, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AppTheme.primaryText.opacity(0.10), lineWidth: 1)
            }
    }
}

extension View {
    func glassListRow(selected: Bool = false, tint: Color? = nil) -> some View {
        #if os(iOS)
        // glassEffect inside listRowBackground traps on iPhone.
        self.listRowBackground(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill((tint ?? AppTheme.primaryText).opacity(selected ? 0.20 : 0.10))
                .padding(.vertical, 2)
        )
        #else
        self.listRowBackground(GlassListRowBackground(selected: selected, tint: tint))
        #endif
    }

    /// Menu outside the system toolbar: glass on the label only, no extra chevron.
    func panelGlassMenu() -> some View {
        self
            .menuIndicator(.hidden)
            .buttonStyle(GlassChipButtonStyle())
    }

    /// Full-width tappable list row label (macOS otherwise only hits the text glyphs).
    func glassRowHitTarget() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
    }
}
