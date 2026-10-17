import SwiftUI

struct FieldFormatBar: View {
    @Binding var text: String
    var isClozeType: Bool = false
    var onAction: ((FieldFormattingAction, String) -> Void)? = nil
    var onMedia: (() -> Void)? = nil
    var isRecording = false
    var onRecord: (() -> Void)? = nil

    private let colors: [(name: String, hex: String)] = [
        ("Vermelho", "#ef4444"), ("Laranja", "#f97316"), ("Amarelo", "#eab308"),
        ("Verde", "#22c55e"), ("Azul", "#3b82f6"), ("Roxo", "#a855f7"),
        ("Preto", "#000000"), ("Branco", "#ffffff")
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    formatButton("B", action: .bold) { wrap("<b>", "</b>") }
                    formatButton("I", action: .italic) { wrap("<i>", "</i>") }
                    formatButton("U", action: .underline) { wrap("<u>", "</u>") }
                    formatButton("Aa", action: .larger) { wrap("<span style=\"font-size:1.2em\">", "</span>") }
                    colorMenu
                    formatMenu
                    Divider().frame(height: 18)
                    formatButton("Sound", action: .sound) { insert("[sound:]") }
                    formatButton("Img", action: .image) { insert(#"<img src="">"#) }
                    if let onRecord {
                        Button(action: onRecord) {
                            Label(isRecording ? "Parar" : "Gravar", systemImage: isRecording ? "stop.fill" : "mic.fill")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(GlassChipButtonStyle(tint: isRecording ? AppTheme.danger.opacity(0.32) : AppTheme.mist.opacity(0.22)))
                        .accessibilityLabel(isRecording ? "Parar gravação de áudio" : "Gravar áudio no campo")
                    }
                    if isClozeType {
                        formatButton("Cloze", action: .cloze) { insertCloze() }
                    }
                    formatButton("∑", action: .math) { insert("\\(\\)") }
                    formatButton("BR", action: .lineBreak) { insert("<br>") }
                    formatButton("Code", action: .code) { wrap("<code>", "</code>") }
                }
            }
        }
    }

    private var colorMenu: some View {
        Menu {
            Section("Cor do texto") {
                ForEach(colors.indices, id: \.self) { index in
                    let color = colors[index]
                    Button {
                        onAction?(.textColor, color.hex)
                    } label: {
                        Label(color.name, systemImage: "textformat")
                    }
                }
            }
            Section("Realce") {
                ForEach(colors.indices.filter { colors[$0].name != "Branco" && colors[$0].name != "Preto" }, id: \.self) { index in
                    let color = colors[index]
                    Button {
                        onAction?(.highlight, color.hex)
                    } label: {
                        Label(color.name, systemImage: "highlighter")
                    }
                }
                Button("Sem realce", systemImage: "eraser") {
                    onAction?(.highlight, "transparent")
                }
            }
        } label: {
            chipLabel("Cor")
        }
        .buttonStyle(GlassChipButtonStyle(tint: AppTheme.mist.opacity(0.22)))
    }

    private var formatMenu: some View {
        Menu {
            Section("Texto") {
                Button("Sobrescrito", systemImage: "textformat.superscript") { onAction?(.superscript, "") }
                Button("Subscrito", systemImage: "textformat.subscript") { onAction?(.subscriptText, "") }
                Button("Limpar formatação", systemImage: "textformat.clear") { onAction?(.removeFormatting, "") }
            }
            Section("Parágrafo") {
                Button("Lista com marcadores", systemImage: "list.bullet") { onAction?(.unorderedList, "") }
                Button("Lista numerada", systemImage: "list.number") { onAction?(.orderedList, "") }
                Button("Recuar", systemImage: "decrease.indent") { onAction?(.outdent, "") }
                Button("Aumentar recuo", systemImage: "increase.indent") { onAction?(.indent, "") }
                Button("Alinhar à esquerda", systemImage: "text.alignleft") { onAction?(.alignLeft, "") }
                Button("Centralizar", systemImage: "text.aligncenter") { onAction?(.alignCenter, "") }
                Button("Alinhar à direita", systemImage: "text.alignright") { onAction?(.alignRight, "") }
            }
        } label: {
            chipLabel("Mais")
        }
        .buttonStyle(GlassChipButtonStyle(tint: AppTheme.mist.opacity(0.22)))
    }

    private func chipLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }

    private func formatButton(_ title: String, action: FieldFormattingAction, fallback: @escaping () -> Void) -> some View {
        Button {
            if (action == .image || action == .sound), let onMedia {
                onMedia()
            } else if let onAction { onAction(action, "") } else { fallback() }
        } label: {
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
