import SwiftUI

struct CardInfoView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .ankiGlass(tint: .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                        .padding()
                }
            }
            .navigationTitle("Info do cartão")
            .safeAreaInset(edge: .bottom) {
                Button("Fechar") { dismiss() }
                    .buttonStyle(GlassButtonStyle(tint: .white, tintStrength: 0.18, expands: true))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
            }
        }
    }
}
