import SwiftUI

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

enum PlatformSupport {
    static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}

struct ShareSheet: View {
    let items: [Any]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(iOS)
        ShareSheetIOS(items: items)
        #else
        ShareSheetMac(items: items, onDone: { dismiss() })
        #endif
    }
}

struct ShareSheetItem: Identifiable {
    let id = UUID()
    let url: URL
}

#if os(iOS)
private struct ShareSheetIOS: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

#if os(macOS)
private struct ShareSheetMac: View {
    let items: [Any]
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Export ready")
                .font(.headline)
            if let url = items.first as? URL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    onDone()
                }
                .buttonStyle(GlassButtonStyle())
            }
            Button("Close", action: onDone)
        }
        .padding(28)
        .frame(minWidth: 320, minHeight: 160)
    }
}
#endif

extension View {
    @ViewBuilder
    func ankiKeyboardDismissToolbar() -> some View {
        #if os(iOS)
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
        #else
        self
        #endif
    }

    @ViewBuilder
    func ankiKeyboardType(_ type: AnkiKeyboardType) -> some View {
        #if os(iOS)
        self.keyboardType(type.uiKit)
        #else
        self
        #endif
    }
}

enum AnkiKeyboardType {
    case decimalPad
    #if os(iOS)
    var uiKit: UIKeyboardType {
        switch self {
        case .decimalPad: .decimalPad
        }
    }
    #endif
}
