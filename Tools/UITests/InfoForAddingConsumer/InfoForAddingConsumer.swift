import SwiftUI
import UIKit

@main
struct AnkiInfoConsumerApp: App {
    var body: some Scene {
        WindowGroup {
            InfoPayloadView()
        }
    }
}

private struct InfoPayloadView: View {
    @State private var payload = "Ainda não lido"

    var body: some View {
        VStack(spacing: 24) {
            PasteControlReceiver()

            Text(payload)
                .textSelection(.enabled)
                .accessibilityIdentifier("infoConsumer.payload")
        }
        .padding(24)
    }
}

private struct PasteControlReceiver: UIViewRepresentable {
    func makeUIView(context: Context) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12

        let textView = InfoPayloadTextView()
        textView.accessibilityIdentifier = "infoConsumer.pasteTarget"
        textView.heightAnchor.constraint(equalToConstant: 140).isActive = true

        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        let control = UIPasteControl(configuration: configuration)
        control.accessibilityIdentifier = "infoConsumer.pasteControl"
        control.target = textView

        stack.addArrangedSubview(control)
        stack.addArrangedSubview(textView)
        return stack
    }

    func updateUIView(_ uiView: UIStackView, context: Context) {}
}

private final class InfoPayloadTextView: UITextView {
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: ["net.ankimobile.json"])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: ["net.ankimobile.json"])
    }

    override func paste(itemProviders: [NSItemProvider]) {
        let pasteboard = UIPasteboard.general
        guard let data = pasteboard.data(forPasteboardType: "net.ankimobile.json"),
              let text = String(data: data, encoding: .utf8) else {
            text = "Payload indisponível"
            return
        }
        self.text = text
        pasteboard.setData(Data(), forPasteboardType: "net.ankimobile.json")
    }
}
