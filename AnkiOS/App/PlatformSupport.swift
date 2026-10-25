import SwiftUI
import UIKit

struct ShareSheet: View {
    let items: [Any]

    var body: some View {
        ShareSheetIOS(items: items)
    }
}

struct ShareSheetItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ShareSheetIOS: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension View {
    @ViewBuilder
    func ankiKeyboardDismissToolbar() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Ocultar teclado", systemImage: "keyboard.chevron.compact.down") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .labelStyle(.iconOnly)
                .tint(AppTheme.accent)
            }
        }
    }

    @ViewBuilder
    func ankiKeyboardType(_ type: AnkiKeyboardType) -> some View {
        self.keyboardType(type.uiKit)
    }
}

enum AnkiKeyboardType {
    case decimalPad
    var uiKit: UIKeyboardType {
        switch self {
        case .decimalPad: .decimalPad
        }
    }
}
