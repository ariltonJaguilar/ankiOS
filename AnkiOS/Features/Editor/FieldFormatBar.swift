import SwiftUI

struct FieldFormatBar: View {
    @Binding var text: String
    var isClozeType: Bool = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                formatButton("B") { wrap("<b>", "</b>") }
                formatButton("I") { wrap("<i>", "</i>") }
                formatButton("U") { wrap("<u>", "</u>") }
                formatButton("Aa") { wrap("<span style=\"font-size:1.2em\">", "</span>") }
                Divider().frame(height: 18)
                formatButton("Sound") { insert("[sound:]") }
                formatButton("Img") { insert(#"<img src="">"#) }
                if isClozeType {
                    formatButton("Cloze") { insertCloze() }
                }
                formatButton("∑") { insert("\\(\\)") }
                formatButton("BR") { insert("<br>") }
                formatButton("Code") { wrap("<code>", "</code>") }
            }
        }
    }

    private func formatButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .buttonStyle(GlassChipButtonStyle(tint: AppTheme.mist.opacity(0.22)))
    }

    private func wrap(_ open: String, _ close: String) {
        if text.isEmpty {
            text = open + close
        } else {
            text = open + text + close
        }
    }

    private func insert(_ snippet: String) {
        text += snippet
    }

    private func insertCloze() {
        let n = (text.components(separatedBy: "{{c").count)
        let idx = max(n, 1)
        if text.isEmpty {
            text = "{{c\(idx)::}}"
        } else {
            text = "{{c\(idx)::\(text)}}"
        }
    }
}
