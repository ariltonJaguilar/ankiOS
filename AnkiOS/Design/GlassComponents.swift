import SwiftUI

struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 20
    var tint: Color = .white.opacity(0.07)
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
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
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .frame(maxWidth: expands ? .infinity : nil)
            .padding(.horizontal, prominent ? 20 : 14)
            .padding(.vertical, prominent ? 14 : 8)
            .glassEffect(
                .regular.tint(tint.opacity(tintStrength)).interactive(),
                in: .capsule
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct GlassChipButtonStyle: ButtonStyle {
    var tint: Color = .white.opacity(0.14)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular.tint(tint).interactive(), in: .capsule)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Compact Liquid Glass for navigation/toolbar actions (Fechar, Salvar, Cancelar…).
/// Uses plain chrome so the system toolbar doesn’t replace the glass capsule.
struct GlassToolbarButtonStyle: ButtonStyle {
    var tint: Color = .white
    var tintStrength: Double = 0.16
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(prominent ? .semibold : .medium))
            .foregroundStyle(.white)
            .labelStyle(.titleAndIcon)
            .symbolRenderingMode(.hierarchical)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Capsule())
            .glassEffect(
                .regular.tint((prominent ? AppTheme.accent : tint).opacity(prominent ? 0.36 : tintStrength)).interactive(),
                in: .capsule
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

struct CountChip: View {
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.7), radius: 3)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(count)")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(color)
                .shadow(color: color.opacity(0.5), radius: 4)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(color.opacity(0.18)), in: .capsule)
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
            .shadow(color: color.opacity(0.55), radius: 5)
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
                .glassEffect(.regular.tint(AppTheme.accent.opacity(0.22)), in: .circle)
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
        .glassEffect(.regular.tint(.white.opacity(0.07)), in: .rect(cornerRadius: 28))
        .padding()
    }
}

struct GlassListRowBackground: View {
    var selected: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.clear)
            .glassEffect(
                .regular.tint(.white.opacity(selected ? 0.14 : 0.06)),
                in: .rect(cornerRadius: 14)
            )
            .padding(.vertical, 2)
    }
}

/// One Liquid Glass row: label on the left, its control on the right.
struct GlassOptionRow<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
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
        .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 14))
    }
}

/// Menu whose selected value stays on one line and truncates inside the row.
struct GlassChoiceMenu<ID: Hashable>: View {
    @Binding var selection: ID
    let choices: [GlassChoice<ID>]

    private var selectedTitle: String {
        choices.first { $0.id == selection }?.title ?? "—"
    }

    var body: some View {
        Menu {
            ForEach(choices) { choice in
                Button {
                    selection = choice.id
                } label: {
                    if choice.id == selection {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Text(choice.title)
                    }
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
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }
}

struct GlassChoice<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
}

struct GlassFormSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
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
            .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 14))
    }
}

extension View {
    func glassListRow(selected: Bool = false) -> some View {
        #if os(iOS)
        // glassEffect inside listRowBackground traps on iPhone.
        self.listRowBackground(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.14 : 0.06))
                .padding(.vertical, 2)
        )
        #else
        self.listRowBackground(GlassListRowBackground(selected: selected))
        #endif
    }

    /// Apply Liquid Glass to toolbar / nav-bar buttons.
    func glassToolbar(prominent: Bool = false) -> some View {
        buttonStyle(GlassToolbarButtonStyle(prominent: prominent))
    }

    /// Menu outside the system toolbar: glass on the label only, no extra chevron.
    func panelGlassMenu() -> some View {
        self
            .menuIndicator(.hidden)
            .buttonStyle(GlassChipButtonStyle())
    }

    /// Menu in a toolbar/action bar: one glass pill, no system ▾ stacked on top.
    func glassMenuToolbar(prominent: Bool = false) -> some View {
        self
            .menuIndicator(.hidden)
            .buttonStyle(GlassToolbarButtonStyle(prominent: prominent))
    }

    /// Full-width tappable list row label (macOS otherwise only hits the text glyphs).
    func glassRowHitTarget() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
    }
}
