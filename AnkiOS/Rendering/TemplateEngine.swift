import Foundation

enum TemplateEngine {
    static func templateHasTypeAnswer(_ template: String) -> Bool {
        template.range(of: #"\{\{type:[^}]+\}\}"#, options: .regularExpression) != nil
    }

    static func typeAnswerFieldName(in template: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{type:([^}]+)\}\}"#),
              let match = regex.firstMatch(in: template, range: NSRange(template.startIndex..., in: template)),
              let r = Range(match.range(at: 1), in: template) else { return nil }
        let raw = String(template[r])
        if raw.hasPrefix("cloze:") { return String(raw.dropFirst(6)) }
        return raw
    }

    static func render(
        template: String,
        fields: [String: String],
        frontSide: String? = nil,
        clozeOrd: Int? = nil,
        questionSide: Bool,
        typedAnswer: String? = nil,
        omitTypeInput: Bool = false
    ) -> String {
        var text = template
        if let frontSide {
            text = text.replacingOccurrences(of: "{{FrontSide}}", with: frontSide)
        }

        text = processConditionals(text, fields: fields)

        // Expand {{cloze:Field}} / {{cloze-only:Field}} before cloze processing.
        for (name, value) in fields {
            text = text.replacingOccurrences(of: "{{cloze:\(name)}}", with: value)
            text = text.replacingOccurrences(of: "{{cloze-only:\(name)}}", with: value)
            text = text.replacingOccurrences(of: "{{type:cloze:\(name)}}", with: value)
        }

        if let clozeOrd {
            text = processCloze(text, ord: clozeOrd + 1, question: questionSide)
        }

        for (name, value) in fields {
            text = text.replacingOccurrences(of: "{{text:\(name)}}", with: stripHTML(value))
            text = text.replacingOccurrences(of: "{{hint:\(name)}}", with: hintHTML(value))
            if questionSide {
                let replacement = omitTypeInput
                    ? ""
                    : #"<input class="typeans" id="typeans" autocomplete="off" value="">"#
                text = text.replacingOccurrences(of: "{{type:\(name)}}", with: replacement)
            } else {
                let expected = stripHTML(value)
                let typed = typedAnswer ?? ""
                let ok = normalizeAnswer(typed) == normalizeAnswer(expected)
                let cssClass = ok ? "typeGood" : "typeBad"
                let shown = typed.isEmpty
                    ? expected
                    : (ok
                       ? expected
                       : "<span class=\"typeBad\">\(escapeHTML(typed))</span> → <span class=\"typeGood\">\(escapeHTML(expected))</span>")
                text = text.replacingOccurrences(
                    of: "{{type:\(name)}}",
                    with: "<div class=\"\(cssClass)\">\(shown)</div>"
                )
            }
            text = text.replacingOccurrences(of: "{{\(name)}}", with: value)
        }

        if let regex = try? NSRegularExpression(pattern: #"\{\{[^}]+\}\}"#) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }

        text = text.replacingOccurrences(
            of: #"\[sound:([^\]]+)\]"#,
            with: #"<div class="sound" data-file="$1">▶</div>"#,
            options: .regularExpression
        )

        return text
    }

    static func normalizeAnswer(_ s: String) -> String {
        stripHTML(s)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func typeAnswerMatches(typed: String, expected: String) -> Bool {
        normalizeAnswer(typed) == normalizeAnswer(expected)
    }

    private static func processConditionals(_ input: String, fields: [String: String]) -> String {
        var text = input
        if let regex = try? NSRegularExpression(pattern: #"\{\{#([^}]+)\}\}([\s\S]*?)\{\{/\1\}\}"#, options: []) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
            for match in matches {
                guard let nameR = Range(match.range(at: 1), in: text),
                      let bodyR = Range(match.range(at: 2), in: text),
                      let full = Range(match.range, in: text) else { continue }
                let name = String(text[nameR])
                let body = String(text[bodyR])
                let value = fields[name] ?? ""
                text.replaceSubrange(full, with: value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : body)
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"\{\{\^([^}]+)\}\}([\s\S]*?)\{\{/\1\}\}"#, options: []) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
            for match in matches {
                guard let nameR = Range(match.range(at: 1), in: text),
                      let bodyR = Range(match.range(at: 2), in: text),
                      let full = Range(match.range, in: text) else { continue }
                let name = String(text[nameR])
                let body = String(text[bodyR])
                let value = fields[name] ?? ""
                text.replaceSubrange(full, with: value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? body : "")
            }
        }
        return text
    }

    private static func processCloze(_ input: String, ord: Int, question: Bool) -> String {
        var text = input
        let pattern = try! NSRegularExpression(pattern: #"\{\{c(\d+(?:,\d+)*)::([^}]*)\}\}"#)
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
        for match in matches {
            guard let nR = Range(match.range(at: 1), in: text),
                  let bodyR = Range(match.range(at: 2), in: text),
                  let full = Range(match.range, in: text) else { continue }
            let ords = text[nR].split(separator: ",").compactMap { Int($0) }
            let body = String(text[bodyR])
            let active = ords.contains(ord)
            let replacement: String
            if body.hasPrefix("image-occlusion:") {
                replacement = imageOcclusionHTML(body, ords: ords, active: active, question: question)
            } else {
                let parts = body.components(separatedBy: "::")
                let answer = parts.first ?? body
                let hint = parts.count > 1 ? parts[1] : "..."
                if active {
                    replacement = question
                        ? "<span class=\"cloze\">[\(escapeHTML(hint))]</span>"
                        : "<span class=\"cloze\">\(answer)</span>"
                } else {
                    replacement = answer
                }
            }
            text.replaceSubrange(full, with: replacement)
        }
        return text
    }

    /// Anki renders `image-occlusion:rect:left=…` as an absolutely positioned mask.
    private static func imageOcclusionHTML(_ body: String, ords: [Int], active: Bool, question: Bool) -> String {
        let payload = body.dropFirst("image-occlusion:".count)
        let bits = payload.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let shape = bits.first ?? "rect"
        var attrs: [String: String] = [:]
        for bit in bits.dropFirst() {
            let pair = bit.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            attrs[pair[0]] = pair[1].replacingOccurrences(of: "\\:", with: ":")
        }
        let occludeInactive = attrs["oi"] == "1"
        var classes = ["cloze", "io-mask"]
        if question {
            classes.append(active || occludeInactive ? "io-covered" : "io-hidden")
        } else if active {
            classes.append("io-revealed")
        } else {
            classes.append(occludeInactive ? "io-covered" : "io-hidden")
        }
        let ordinal = ords.map(String.init).joined(separator: ",")
        func attr(_ key: String, _ data: String, fallback: String = "0") -> String {
            let value = (attrs[key] ?? fallback)
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            return " data-\(data)=\"\(value)\""
        }
        return """
        <div class="\(classes.joined(separator: " "))" data-ordinal="\(ordinal)" data-shape="\(escapeHTML(shape))"\(attr("left", "left"))\(attr("top", "top"))\(attr("width", "width"))\(attr("height", "height"))\(attr("points", "points", fallback: ""))></div>
        """
    }

    private static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func hintHTML(_ s: String) -> String {
        let stripped = stripHTML(s)
        guard !stripped.isEmpty else { return "" }
        return "<details><summary>Mostrar dica</summary>\(s)</details>"
    }

    static func fieldMap(note: AnkiNote, notetype: AnkiNotetype, deckName: String = "") -> [String: String] {
        var map: [String: String] = [:]
        let values = note.fields
        for field in notetype.flds {
            let value = field.ord < values.count ? values[field.ord] : ""
            map[field.name] = value
        }
        map["Tags"] = note.tagList.joined(separator: " ")
        map["Type"] = notetype.name
        map["Card"] = ""
        map["Deck"] = deckName
        map["Subdeck"] = deckName.components(separatedBy: "::").last ?? deckName
        return map
    }
}
