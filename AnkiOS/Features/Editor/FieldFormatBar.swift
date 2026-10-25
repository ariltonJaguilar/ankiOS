import SwiftUI

struct FieldFormatBar: View {
    @Binding var text: String
    let fieldName: String
    var isClozeType: Bool = false
    var onAction: ((FieldFormattingAction, String) -> Void)? = nil
    var onMenuOpen: (() -> Void)? = nil
    var onMedia: (() -> Void)? = nil
    var isRecording = false
    var onRecord: (() -> Void)? = nil
    var recordButtonTitle: LocalizedStringKey = "Gravar"
    var showsRecordButton = true

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
                    formatButton("Fx", action: .removeFormatting, fallback: nil)
                    formatButton("A¹", action: .superscript) { wrap("<sup>", "</sup>") }
                        .accessibilityLabel("Sobrescrito")
                    formatButton("A₁", action: .subscriptText) { wrap("<sub>", "</sub>") }
                        .accessibilityLabel("Subscrito")
                    formatButton("•", action: .unorderedList) { wrap("<ul><li>", "</li></ul>") }
                        .accessibilityLabel("Lista com marcadores")
                    formatButton("1.", action: .orderedList) { wrap("<ol><li>", "</li></ol>") }
                        .accessibilityLabel("Lista numerada")
                    colorMenu
                    formatMenu
                    Divider().frame(height: 18)
                    if let onMedia {
                        Button(action: onMedia) {
                            Label("Add Media", systemImage: "paperclip")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(GlassChipButtonStyle(tint: AppTheme.mist.opacity(0.22)))
                        .accessibilityIdentifier("field.addMedia.\(fieldName)")
                    }
                    if let onRecord, showsRecordButton {
                        Button(action: onRecord) {
                            Label(isRecording ? "Parar" : recordButtonTitle, systemImage: isRecording ? "stop.fill" : "mic.fill")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(GlassChipButtonStyle(tint: isRecording ? AppTheme.danger.opacity(0.32) : AppTheme.mist.opacity(0.22)))
                        .accessibilityLabel(isRecording ? "Parar gravação de áudio" : recordButtonTitle)
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
        .accessibilityIdentifier("field.formatBar.\(fieldName)")
    }

    private var colorMenu: some View {
        Menu {
            Section("Cor do texto") {
                ForEach(colors.indices, id: \.self) { index in
                    let color = colors[index]
                    Button {
                        onAction?(.textColor, color.hex)
                    } label: {
                        Label {
                            Text(LocalizedStringKey(color.name))
                        } icon: {
                            Image(systemName: "textformat")
                        }
                    }
                }
            }
            Section("Realce") {
                ForEach(colors.indices.filter { colors[$0].name != "Branco" && colors[$0].name != "Preto" }, id: \.self) { index in
                    let color = colors[index]
                    Button {
                        onAction?(.highlight, color.hex)
                    } label: {
                        Label {
                            Text(LocalizedStringKey(color.name))
                        } icon: {
                            Image(systemName: "highlighter")
                        }
                    }
                }
                Button("Sem realce", systemImage: "eraser") {
                    onAction?(.highlight, "transparent")
                }
            }
        } label: {
            chipLabel("Cor")
                .simultaneousGesture(TapGesture().onEnded { onMenuOpen?() })
        }
        .buttonStyle(GlassChipButtonStyle(tint: AppTheme.mist.opacity(0.22)))
    }

    private var formatMenu: some View {
        Menu {
            Section("Parágrafo") {
                Button("Recuar", systemImage: "decrease.indent") { onAction?(.outdent, "") }
                Button("Aumentar recuo", systemImage: "increase.indent") { onAction?(.indent, "") }
                Button("Alinhar à esquerda", systemImage: "text.alignleft") { onAction?(.alignLeft, "") }
                Button("Centralizar", systemImage: "text.aligncenter") { onAction?(.alignCenter, "") }
                Button("Alinhar à direita", systemImage: "text.alignright") { onAction?(.alignRight, "") }
            }
        } label: {
            chipLabel("Mais")
                .simultaneousGesture(TapGesture().onEnded { onMenuOpen?() })
        }
        .buttonStyle(GlassChipButtonStyle(tint: AppTheme.mist.opacity(0.22)))
    }

    private func chipLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }

    private func formatButton(_ title: LocalizedStringKey, action: FieldFormattingAction, fallback: (() -> Void)?) -> some View {
        Button {
            if (action == .image || action == .sound), let onMedia {
                onMedia()
            } else if let onAction { onAction(action, "") } else { fallback?() }
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
