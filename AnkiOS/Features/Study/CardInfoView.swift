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
                        .glassEffect(.regular.tint(.white.opacity(0.07)), in: .rect(cornerRadius: 20))
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
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }
}
