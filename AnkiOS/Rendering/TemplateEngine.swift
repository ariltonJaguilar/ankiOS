import Foundation
import AVFoundation

enum TemplateEngine {
    struct TypeAnswerConfig {
        var fieldName: String
        var cloze: Bool
        var ignoreDiacritics: Bool
        var ignoreCase: Bool
    }

    private indirect enum ClozeNode {
        case text(String)
        case cloze(ordinals: [Int], contents: [ClozeNode], hint: String?)
    }

    private struct ClozeMathState {
        private(set) var closingDelimiter: String?
        private(set) var regionID: Int?
        private var nextRegionID: Int

        init(closingDelimiter: String? = nil, regionID: Int? = nil, nextRegionID: Int = 0) {
            self.closingDelimiter = closingDelimiter
            self.regionID = regionID
            self.nextRegionID = nextRegionID
        }

        mutating func consumeDelimiter(in source: String, at index: String.Index) -> Int? {
            if let closingDelimiter {
                guard source[index...].hasPrefix(closingDelimiter) else { return nil }
                self.closingDelimiter = nil
                regionID = nil
                return closingDelimiter.count
            }
            for (opening, closing) in [("\\(", "\\)"), ("\\[", "\\]")] {
                guard source[index...].hasPrefix(opening) else { continue }
                let contentStart = source.index(index, offsetBy: opening.count)
                guard source[contentStart...].range(of: closing) != nil else { continue }
                closingDelimiter = closing
                regionID = nextRegionID
                nextRegionID += 1
                return opening.count
            }
            return nil
        }
    }

    static func templateHasTypeAnswer(_ template: String) -> Bool {
        typeAnswerConfig(in: template) != nil
    }

    static func normalizedTemplateSyntax(_ template: String) -> String {
        let leadingWhitespace = template.prefix(while: \.isWhitespace)
        let remainder = template.dropFirst(leadingWhitespace.count)
        let directive = "{{=<% %>=}}"
        guard remainder.hasPrefix(directive) else { return template }
        let body = remainder.dropFirst(directive.count)
            .replacingOccurrences(of: "<%", with: "{{")
            .replacingOccurrences(of: "%>", with: "}}")
        return String(leadingWhitespace) + body
    }

    static func removingHTMLComments(from template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#) else { return template }
        return regex.stringByReplacingMatches(
            in: template,
            range: NSRange(template.startIndex..., in: template),
            withTemplate: ""
        )
    }

    static func validationError(template: String, fields: [String: String], questionSide: Bool) -> String? {
        let source = removingHTMLComments(from: normalizedTemplateSyntax(template))
        return conditionalSyntaxError(in: source, fields: fields, questionSide: questionSide)
            ?? missingFieldError(in: source, fields: fields, questionSide: questionSide)
    }

    static func typeAnswerFieldName(in template: String) -> String? {
        typeAnswerConfig(in: template)?.fieldName
    }

    static func typeAnswerConfig(in template: String) -> TypeAnswerConfig? {
        let template = removingHTMLComments(from: normalizedTemplateSyntax(template))
        guard let regex = try? NSRegularExpression(pattern: #"\{\{type(?:(-cloze|-nc))?:((?:(?:cloze|nc|ci):)*)([^}]+)\}\}"#),
              let match = regex.firstMatch(in: template, range: NSRange(template.startIndex..., in: template)),
              let modifiersRange = Range(match.range(at: 2), in: template),
              let nameRange = Range(match.range(at: 3), in: template) else { return nil }
        let alias = Range(match.range(at: 1), in: template).map { String(template[$0]) } ?? ""
        let modifiers = String(template[modifiersRange]).split(separator: ":").map(String.init)
        return TypeAnswerConfig(
            fieldName: String(template[nameRange]),
            cloze: alias == "-cloze" || modifiers.contains("cloze"),
            ignoreDiacritics: alias == "-nc" || modifiers.contains("nc"),
            ignoreCase: modifiers.contains("ci")
        )
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
        let normalizedTemplate = normalizedTemplateSyntax(template)
        var comments: [(token: String, value: String)] = []
        var text = normalizedTemplate
        if let commentRegex = try? NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#) {
            let matches = commentRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for (index, match) in matches.enumerated().reversed() {
                guard let range = Range(match.range, in: text) else { continue }
                let value = String(text[range])
                let token = "ANKIHTMLCOMMENT\(UUID().uuidString)\(index)END"
                comments.append((token, value))
                text.replaceSubrange(range, with: token)
            }
        }
        if let error = conditionalSyntaxError(in: text, fields: fields, questionSide: questionSide) {
            return error
        }
        if let error = missingFieldError(in: text, fields: fields, questionSide: questionSide) {
            return error
        }
        text = processConditionals(text, fields: fields)

        text = processTTS(text, fields: fields, clozeOrd: clozeOrd)
        text = processTypeAnswer(
            text,
            fields: fields,
            clozeOrd: clozeOrd,
            questionSide: questionSide,
            typedAnswer: typedAnswer,
            omitTypeInput: omitTypeInput
        )

        var replacementFields = fields
        replacementFields["FrontSide"] = frontSide ?? ""
        text = processFieldReplacements(text, fields: replacementFields, clozeOrd: clozeOrd, questionSide: questionSide)

        for comment in comments {
            text = text.replacingOccurrences(of: comment.token, with: comment.value)
        }

        text = text.replacingOccurrences(
            of: #"\[sound:([^\]]+)\]"#,
            with: #"<div class="sound" data-file="$1">▶</div>"#,
            options: .regularExpression
        )

        return text
    }

    private static func processFieldReplacements(
        _ input: String,
        fields: [String: String],
        clozeOrd: Int?,
        questionSide: Bool
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#) else { return input }
        var output = input
        for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed() {
            guard let bodyRange = Range(match.range(at: 1), in: output),
                  let fullRange = Range(match.range, in: output) else { continue }
            let expression = String(output[bodyRange])
            let components = expression.components(separatedBy: ":")
            let fieldName = components.last ?? expression
            let fieldFilters = Array(components.dropLast())
            guard var value = fields[fieldName] else {
                output.replaceSubrange(fullRange, with: "")
                continue
            }
            for filter in fieldFilters.reversed() {
                switch filter {
                case "text":
                    value = stripHTML(value)
                case "hint":
                    value = hintHTML(value, fieldName: fieldName)
                case "furigana":
                    value = rubyField(value, mode: .furigana)
                case "kana":
                    value = rubyField(value, mode: .kana)
                case "kanji":
                    value = rubyField(value, mode: .kanji)
                case "cloze":
                    if let clozeOrd { value = processCloze(value, ord: clozeOrd + 1, question: questionSide) }
                case "cloze-only":
                    if let clozeOrd { value = activeClozeText(value, ord: clozeOrd + 1) }
                default:
                    break
                }
            }
            output.replaceSubrange(fullRange, with: value)
        }
        return output
    }

    private static func missingFieldError(in template: String, fields: [String: String], questionSide: Bool) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#) else { return nil }
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let range = Range(match.range(at: 1), in: template) else { continue }
            let expression = String(template[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if expression == "FrontSide" || expression == "tts-voices:" { continue }
            if expression.first == "#" || expression.first == "^" || expression.first == "/" { continue }
            let parts = expression.split(separator: ":", omittingEmptySubsequences: false)
            let fieldName = String(parts.last ?? "")
            if fieldName.isEmpty && parts.count > 1 { continue }
            guard fields[fieldName] == nil else { continue }
            let detail = "Encontrado \(quotedTemplateValue("{{\(expression)}}")), mas não existe o campo chamado \(quotedTemplateValue(fieldName))"
            return templateErrorHTML(detail, questionSide: questionSide)
        }
        return nil
    }

    private static func conditionalSyntaxError(in template: String, fields: [String: String], questionSide: Bool) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{([#^/])([^{}]+)\}\}"#) else { return nil }
        var stack: [String] = []
        var missingConditional: (marker: String, name: String)?
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let markerRange = Range(match.range(at: 1), in: template),
                  let nameRange = Range(match.range(at: 2), in: template) else { continue }
            let marker = String(template[markerRange])
            let name = String(template[nameRange])
            if marker == "#" || marker == "^" {
                stack.append(name)
                if fields[name] == nil, !isClozeConditional(name), missingConditional == nil {
                    missingConditional = (marker, name)
                }
            } else if let open = stack.last {
                guard open == name else {
                    let detail = "Encontrado \(quotedTemplateValue("{{/\(name)}}")), mas se esperava \(quotedTemplateValue("{{/\(open)}}"))"
                    return templateErrorHTML(detail, questionSide: questionSide)
                }
                stack.removeLast()
            } else {
                let detail = "Encontrado \(quotedTemplateValue("{{/\(name)}}")), mas faltando \(quotedTemplateValue("{{#\(name)}}")) ou \(quotedTemplateValue("{{^\(name)}}"))"
                return templateErrorHTML(detail, questionSide: questionSide)
            }
        }
        if let open = stack.last {
            let detail = "Faltando \(quotedTemplateValue("{{/\(open)}}"))"
            return templateErrorHTML(detail, questionSide: questionSide)
        }
        if let missingConditional {
            let found = "{{\(missingConditional.marker)\(missingConditional.name)}}"
            let detail = "Encontrado \(quotedTemplateValue(found)), mas não existe o campo chamado \(quotedTemplateValue(missingConditional.name))"
            return templateErrorHTML(detail, questionSide: questionSide)
        }
        return nil
    }

    private static func isClozeConditional(_ name: String) -> Bool {
        guard name.first == "c" else { return false }
        return UInt32(name.dropFirst()) != nil
    }

    private static func quotedTemplateValue(_ value: String) -> String {
        "&#x27;\u{2068}\(encodeMinimalHTML(value))\u{2069}&#x27;"
    }

    private static func templateErrorHTML(_ detail: String, questionSide: Bool) -> String {
        let header = questionSide ? "O modelo da frente tem um problema:" : "O modelo do verso tem um problema:"
        return "\(header)<br>\(detail)<br><a href='https://docs.ankiweb.net/templates/errors.html#template-syntax-error'>Mais informações</a>"
    }

    static func normalizeAnswer(_ s: String) -> String {
        stripHTML(s)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func typeAnswerText(_ value: String, config: TypeAnswerConfig, clozeOrd: Int?) -> String {
        guard config.cloze, let clozeOrd else { return value }
        return clozeAnswers(value, ord: clozeOrd + 1).joined(separator: ", ")
    }

    static func typeAnswerMatches(typed: String, expected: String, config: TypeAnswerConfig? = nil) -> Bool {
        let options = config ?? TypeAnswerConfig(fieldName: "", cloze: false, ignoreDiacritics: false, ignoreCase: false)
        return comparisonCharacters(typed, config: options) == comparisonCharacters(expectedText(expected), config: options)
    }

    private static func comparisonCharacters(_ value: String, config: TypeAnswerConfig) -> [String] {
        var options: String.CompareOptions = []
        if config.ignoreDiacritics { options.insert(.diacriticInsensitive) }
        if config.ignoreCase { options.insert(.caseInsensitive) }
        return value.precomposedStringWithCanonicalMapping.map {
            String($0).folding(options: options, locale: Locale(identifier: "en_US_POSIX"))
        }
    }

    private static func expectedText(_ value: String) -> String {
        let normalizedLineBreaks = value
            .replacingOccurrences(of: #"(?i)\[sound:[^\]]+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<br\s*/?>|</?div\b[^>]*>"#, with: " ", options: .regularExpression)
        return stripHTML(normalizedLineBreaks)
            .replacingOccurrences(of: "&nbsp;", with: "\u{00a0}")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func typeAnswerComparisonHTML(typed: String, expected: String, config: TypeAnswerConfig) -> String {
        let expected = expectedText(expected)
        guard !typed.isEmpty else {
            return "<code id=typeans>\(escapeHTML(expected))</code>"
        }

        let typedChars = Array(typed.precomposedStringWithCanonicalMapping)
        let expectedChars = Array(expected.precomposedStringWithCanonicalMapping)
        let typedKeys = comparisonCharacters(typed, config: config)
        let expectedKeys = comparisonCharacters(expected, config: config)
        guard typedKeys != expectedKeys else {
            return "<code id=typeans><span class=typeGood>\(escapeHTML(expected))</span></code>"
        }

        guard typedChars.count * expectedChars.count <= 1_000_000 else {
            return "<code id=typeans><span class=typeBad>\(escapeHTML(typed))</span><br><span id=typearrow>&darr;</span><br><span class=typeMissed>\(escapeHTML(expected))</span></code>"
        }

        let width = expectedChars.count + 1
        var lcs = [UInt16](repeating: 0, count: (typedChars.count + 1) * width)
        if !typedChars.isEmpty, !expectedChars.isEmpty {
            for i in stride(from: typedChars.count - 1, through: 0, by: -1) {
                for j in stride(from: expectedChars.count - 1, through: 0, by: -1) {
                    let index = i * width + j
                    if typedKeys[i] == expectedKeys[j] {
                        lcs[index] = lcs[(i + 1) * width + j + 1] + 1
                    } else {
                        lcs[index] = max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
                    }
                }
            }
        }

        enum TokenKind: Equatable { case good, bad, missing }
        var typedTokens: [(TokenKind, String)] = []
        var expectedTokens: [(TokenKind, String)] = []
        func append(_ text: String, kind: TokenKind, to tokens: inout [(TokenKind, String)]) {
            guard !text.isEmpty else { return }
            if let last = tokens.last, last.0 == kind {
                tokens[tokens.count - 1].1 += text
            } else {
                tokens.append((kind, text))
            }
        }

        var i = 0
        var j = 0
        while i < typedChars.count || j < expectedChars.count {
            if i < typedChars.count, j < expectedChars.count, typedKeys[i] == expectedKeys[j] {
                append(String(typedChars[i]), kind: .good, to: &typedTokens)
                append(String(expectedChars[j]), kind: .good, to: &expectedTokens)
                i += 1
                j += 1
            } else if i < typedChars.count,
                      j == expectedChars.count || lcs[(i + 1) * width + j] >= lcs[i * width + j + 1] {
                append(String(typedChars[i]), kind: .bad, to: &typedTokens)
                i += 1
            } else if j < expectedChars.count {
                append(String(repeating: "-", count: 1), kind: .missing, to: &typedTokens)
                append(String(expectedChars[j]), kind: .missing, to: &expectedTokens)
                j += 1
            }
        }

        func html(_ tokens: [(TokenKind, String)]) -> String {
            tokens.map { kind, text in
                let cssClass: String
                switch kind {
                case .good: cssClass = "typeGood"
                case .bad: cssClass = "typeBad"
                case .missing: cssClass = "typeMissed"
                }
                return "<span class=\(cssClass)>\(escapeHTML(text))</span>"
            }.joined()
        }

        return "<code id=typeans>\(html(typedTokens))<br><span id=typearrow>&darr;</span><br>\(html(expectedTokens))</code>"
    }

    private static func processTypeAnswer(
        _ input: String,
        fields: [String: String],
        clozeOrd: Int?,
        questionSide: Bool,
        typedAnswer: String?,
        omitTypeInput: Bool
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{type(?:(-cloze|-nc))?:((?:(?:cloze|nc|ci):)*)([^}]+)\}\}"#) else { return input }
        var output = input
        for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed() {
            guard let modifiersRange = Range(match.range(at: 2), in: output),
                  let nameRange = Range(match.range(at: 3), in: output),
                  let fullRange = Range(match.range, in: output) else { continue }
            let alias = Range(match.range(at: 1), in: output).map { String(output[$0]) } ?? ""
            let modifiers = String(output[modifiersRange]).split(separator: ":").map(String.init)
            let config = TypeAnswerConfig(
                fieldName: String(output[nameRange]),
                cloze: alias == "-cloze" || modifiers.contains("cloze"),
                ignoreDiacritics: alias == "-nc" || modifiers.contains("nc"),
                ignoreCase: modifiers.contains("ci")
            )
            let expected = typeAnswerText(fields[config.fieldName] ?? "", config: config, clozeOrd: clozeOrd)
            let replacement: String
            if questionSide {
                replacement = omitTypeInput ? "" : #"<input class="typeans" id="typeans" autocomplete="off" value="">"#
            } else {
                let typed = typedAnswer ?? ""
                replacement = typeAnswerComparisonHTML(typed: typed, expected: expected, config: config)
            }
            output.replaceSubrange(fullRange, with: replacement)
        }
        return output
    }

    private static func clozeAnswers(_ value: String, ord: Int) -> [String] {
        let answers = activeClozeAnswers(in: parseClozeNodes(value), ord: ord)
        guard let first = answers.first, answers.allSatisfy({ $0 == first }) else { return answers }
        return [first]
    }

    private static func processConditionals(_ input: String, fields: [String: String]) -> String {
        guard let marker = try? NSRegularExpression(pattern: #"\{\{([#^/])([^}]+)\}\}"#) else { return input }

        func render(_ source: String) -> String {
            let matches = marker.matches(in: source, range: NSRange(source.startIndex..., in: source))
            guard let opening = matches.first(where: { match in
                guard let range = Range(match.range(at: 1), in: source) else { return false }
                return source[range] == "#" || source[range] == "^"
            }),
                  let openingNameRange = Range(opening.range(at: 2), in: source),
                  let openingMarkerRange = Range(opening.range(at: 1), in: source) else { return source }

            let name = String(source[openingNameRange])
            var stack = [name]
            var closing: NSTextCheckingResult?
            for match in matches where match.range.location > opening.range.location {
                guard let markerRange = Range(match.range(at: 1), in: source),
                      let fieldRange = Range(match.range(at: 2), in: source) else { continue }
                let kind = source[markerRange]
                let field = String(source[fieldRange])
                if kind == "#" || kind == "^" {
                    stack.append(field)
                } else if stack.last == field {
                    stack.removeLast()
                    if stack.isEmpty {
                        closing = match
                        break
                    }
                }
            }
            guard let closing,
                  let bodyRange = Range(NSRange(location: opening.range.upperBound, length: closing.range.location - opening.range.upperBound), in: source),
                  let prefixRange = Range(NSRange(location: 0, length: opening.range.location), in: source),
                  let suffixRange = Range(NSRange(location: closing.range.upperBound, length: source.utf16.count - closing.range.upperBound), in: source) else {
                return source
            }

            let value = fields[name] ?? ""
            let isEmpty = fieldIsEmpty(value)
            let includeBody = source[openingMarkerRange] == "#" ? !isEmpty : isEmpty
            let body = includeBody ? render(String(source[bodyRange])) : ""
            return String(source[prefixRange]) + body + render(String(source[suffixRange]))
        }

        return render(input)
    }

    private static func fieldIsEmpty(_ value: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"^(?:\s|</?(?:br|div)\s*/?>)*$"#,
            options: [.caseInsensitive]
        ) else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static func processTTS(_ input: String, fields: [String: String], clozeOrd: Int?) -> String {
        var output = input
        output = output.replacingOccurrences(of: "{{tts-voices:}}", with: ttsVoiceList())
        guard let regex = try? NSRegularExpression(
            pattern: #"\{\{tts\s+([A-Za-z0-9_-]+)([^:}]*):([^}]+)\}\}"#
        ) else { return output }
        for match in regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).reversed() {
            guard let languageRange = Range(match.range(at: 1), in: output),
                  let optionsRange = Range(match.range(at: 2), in: output),
                  let fieldRange = Range(match.range(at: 3), in: output),
                  let outputRange = Range(match.range, in: output) else { continue }
            let language = String(output[languageRange])
            let options = String(output[optionsRange])
            let fieldExpression = String(output[fieldRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let clozeOnly = fieldExpression.hasPrefix("cloze-only:")
            let fieldName = clozeOnly ? String(fieldExpression.dropFirst("cloze-only:".count)) : fieldExpression
            var value = fields[fieldName] ?? ""
            if clozeOnly, let clozeOrd {
                value = activeClozeText(value, ord: clozeOrd + 1)
            }
            output.replaceSubrange(outputRange, with: ttsMarker(language: language, options: options, text: value))
        }
        if let blockRegex = try? NSRegularExpression(
            pattern: #"\[anki:tts\s+([^\]]+)\]([\s\S]*?)\[/anki:tts\]"#,
            options: [.caseInsensitive]
        ) {
            for match in blockRegex.matches(in: output, range: NSRange(output.startIndex..., in: output)).reversed() {
                guard let optionsRange = Range(match.range(at: 1), in: output),
                      let bodyRange = Range(match.range(at: 2), in: output),
                      let fullRange = Range(match.range, in: output) else { continue }
                let options = String(output[optionsRange])
                guard let language = ttsOption("lang", in: options) else { continue }
                var body = String(output[bodyRange])
                if let fieldRegex = try? NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#) {
                    for fieldMatch in fieldRegex.matches(in: body, range: NSRange(body.startIndex..., in: body)).reversed() {
                        guard let nameRange = Range(fieldMatch.range(at: 1), in: body),
                              let fullFieldRange = Range(fieldMatch.range, in: body) else { continue }
                        let name = String(body[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let value = fields[name] else { continue }
                        body.replaceSubrange(fullFieldRange, with: value)
                    }
                }
                output.replaceSubrange(fullRange, with: ttsMarker(language: language, options: options, text: body))
            }
        }
        return output
    }

    private static func ttsVoiceList() -> String {
        let voices = AVSpeechSynthesisVoice.speechVoices().sorted {
            if $0.language == $1.language { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return $0.language.localizedCaseInsensitiveCompare($1.language) == .orderedAscending
        }
        guard !voices.isEmpty else { return "" }
        let rows = voices.map { voice in
            "<li><code>\(escapeHTML(voice.language))</code> \(escapeHTML(voice.name)) <code>\(escapeHTML(voice.identifier))</code></li>"
        }.joined()
        return "<ul class=\"tts-voices\">\(rows)</ul>"
    }

    private static func ttsOption(_ name: String, in options: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|\s)\#(NSRegularExpression.escapedPattern(for: name))=([^\s]+)"#),
              let match = regex.firstMatch(in: options, range: NSRange(options.startIndex..., in: options)),
              let range = Range(match.range(at: 1), in: options) else { return nil }
        return String(options[range])
    }

    private static func ttsMarker(language: String, options: String, text: String) -> String {
        let speed = ttsOption("speed", in: options) ?? "1"
        let voices = ttsOption("voices", in: options)?.split(separator: ",").map(String.init) ?? []
        let encoded = Data(text.utf8).base64EncodedString()
        let encodedVoices = (try? JSONEncoder().encode(voices).base64EncodedString()) ?? ""
        return #"<anki-tts data-lang="\#(language)" data-speed="\#(speed)" data-voices="\#(encodedVoices)" data-text="\#(encoded)">🔊</anki-tts>"#
    }

    private static func activeClozeText(_ value: String, ord: Int) -> String {
        activeClozeAnswers(in: parseClozeNodes(value), ord: ord).joined(separator: ", ")
    }

    private static func processCloze(_ input: String, ord: Int, question: Bool) -> String {
        var activeFound = false
        let rendered = renderClozeNodes(parseClozeNodes(input), ord: ord, question: question, activeFound: &activeFound)
        return activeFound ? rendered : ""
    }

    private static func parseClozeNodes(_ source: String) -> [ClozeNode] {
        parseClozeNodes(source, math: ClozeMathState())
    }

    private static func parseClozeNodes(_ source: String, math: ClozeMathState) -> [ClozeNode] {
        var nodes: [ClozeNode] = []
        var cursor = source.startIndex
        var textStart = cursor
        var currentMath = math
        while cursor < source.endIndex {
            guard let opening = clozeOpening(in: source, at: cursor) else {
                if let consumed = currentMath.consumeDelimiter(in: source, at: cursor) {
                    cursor = source.index(cursor, offsetBy: consumed)
                    continue
                }
                cursor = source.index(after: cursor)
                continue
            }
            let openingMath = currentMath
            var scan = opening.contentsStart
            var scanMath = openingMath
            var nested = 0
            var clozeRegions: [Int?] = [openingMath.regionID]
            var closing: String.Index?
            while scan < source.endIndex {
                if let nestedOpening = clozeOpening(in: source, at: scan) {
                    nested += 1
                    clozeRegions.append(scanMath.regionID)
                    scan = nestedOpening.contentsStart
                    continue
                }
                if source[scan...].hasPrefix("}}"), clozeRegions.last == scanMath.regionID {
                    if nested == 0 {
                        closing = scan
                        break
                    }
                    nested -= 1
                    clozeRegions.removeLast()
                    scan = source.index(scan, offsetBy: 2)
                    continue
                }
                if let consumed = scanMath.consumeDelimiter(in: source, at: scan) {
                    scan = source.index(scan, offsetBy: consumed)
                    continue
                }
                scan = source.index(after: scan)
            }
            guard let closing else {
                cursor = source.index(after: cursor)
                continue
            }
            if textStart < cursor { nodes.append(.text(String(source[textStart..<cursor]))) }
            let rawContents = String(source[opening.contentsStart..<closing])
            let separator = clozeHintSeparator(in: rawContents)
            let body: String
            let hint: String?
            if let separator {
                body = String(rawContents[..<separator])
                hint = String(rawContents[rawContents.index(separator, offsetBy: 2)...])
            } else {
                body = rawContents
                hint = nil
            }
            nodes.append(.cloze(ordinals: opening.ordinals, contents: parseClozeNodes(body, math: openingMath), hint: hint))
            cursor = source.index(closing, offsetBy: 2)
            textStart = cursor
            currentMath = openingMath
        }
        if textStart < source.endIndex { nodes.append(.text(String(source[textStart...]))) }
        return nodes
    }

    private static func clozeOpening(in source: String, at index: String.Index) -> (ordinals: [Int], contentsStart: String.Index)? {
        guard source[index...].hasPrefix("{{c") else { return nil }
        var cursor = source.index(index, offsetBy: 3)
        let ordinalStart = cursor
        while cursor < source.endIndex {
            let scalar = source[cursor].unicodeScalars.first?.value
            guard scalar == 44 || (scalar.map { 48...57 ~= $0 } ?? false) else { break }
            cursor = source.index(after: cursor)
        }
        guard ordinalStart < cursor, source[cursor...].hasPrefix("::") else { return nil }
        let ordinals = source[ordinalStart..<cursor].split(separator: ",").compactMap { Int($0) }
        guard !ordinals.isEmpty else { return nil }
        return (ordinals, source.index(cursor, offsetBy: 2))
    }

    private static func clozeHintSeparator(in source: String) -> String.Index? {
        var cursor = source.startIndex
        var nested = 0
        while cursor < source.endIndex {
            if let opening = clozeOpening(in: source, at: cursor) {
                nested += 1
                cursor = opening.contentsStart
                continue
            }
            if source[cursor...].hasPrefix("}}"), nested > 0 {
                nested -= 1
                cursor = source.index(cursor, offsetBy: 2)
                continue
            }
            if nested == 0, source[cursor...].hasPrefix("::") { return cursor }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func activeClozeAnswers(in nodes: [ClozeNode], ord: Int) -> [String] {
        var answers: [String] = []
        func visit(_ nodes: [ClozeNode]) {
            for node in nodes {
                guard case let .cloze(ordinals, contents, _) = node else { continue }
                if ordinals.contains(ord) { answers.append(plainClozeText(contents)) }
                visit(contents)
            }
        }
        visit(nodes)
        return answers
    }

    private static func plainClozeText(_ nodes: [ClozeNode]) -> String {
        nodes.map { node in
            switch node {
            case .text(let value): value
            case .cloze(_, let contents, _): plainClozeText(contents)
            }
        }.joined()
    }

    private static func renderClozeNodes(
        _ nodes: [ClozeNode],
        ord: Int,
        question: Bool,
        activeFound: inout Bool
    ) -> String {
        var output = ""
        for node in nodes {
            switch node {
            case .text(let value):
                output += value
            case .cloze(let ordinals, let contents, let hint):
                let active = ordinals.contains(ord)
                activeFound = activeFound || active
                let ordinal = ordinals.map(String.init).joined(separator: ",")
                let contentText = plainClozeText(contents)
                if contentText.hasPrefix("image-occlusion:") {
                    output += imageOcclusionHTML(contentText, ords: ordinals, active: active, question: question)
                    continue
                }
                let renderedContents = renderClozeNodes(contents, ord: ord, question: question, activeFound: &activeFound)
                if active && question {
                    output += "<span class=\"cloze\" data-cloze=\"\(escapeAttribute(renderedContents))\" data-ordinal=\"\(ordinal)\">[\(hint.map(escapeHTML) ?? "...")]</span>"
                } else if active {
                    output += "<span class=\"cloze\" data-ordinal=\"\(ordinal)\">\(renderedContents)</span>"
                } else {
                    output += "<span class=\"cloze-inactive\" data-ordinal=\"\(ordinal)\">\(renderedContents)</span>"
                }
            }
        }
        return output
    }

    private static func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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
        guard let regex = try? NSRegularExpression(
            pattern: #"(?si)<!--.*?-->|<style.*?>.*?</style>|<script.*?>.*?</script>|<.*?>"#
        ) else { return s }
        let stripped = regex.stringByReplacingMatches(
            in: s,
            range: NSRange(s.startIndex..., in: s),
            withTemplate: ""
        )
        return decodeHTMLEntities(stripped) ?? stripped
    }

    private static func decodeHTMLEntities(_ input: String) -> String? {
        var output = ""
        var cursor = input.startIndex
        while cursor < input.endIndex {
            guard input[cursor] == "&" else {
                output.append(input[cursor])
                cursor = input.index(after: cursor)
                continue
            }
            guard let semicolon = input[cursor...].firstIndex(of: ";") else { return nil }
            let nameStart = input.index(after: cursor)
            let name = String(input[nameStart..<semicolon])
            let value: UInt32?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                value = UInt32(name.dropFirst(2), radix: 16)
            } else if name.hasPrefix("#") {
                value = UInt32(name.dropFirst())
            } else {
                value = namedHTMLEntities[name]
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            output.unicodeScalars.append(scalar)
            cursor = input.index(after: semicolon)
        }
        return output.replacingOccurrences(of: "\u{00a0}", with: " ")
    }

    private static let namedHTMLEntities: [String: UInt32] = {
        let values = """
            AElig=198
            Aacute=193
            Acirc=194
            Agrave=192
            Alpha=913
            Aring=197
            Atilde=195
            Auml=196
            Beta=914
            Ccedil=199
            Chi=935
            Dagger=8225
            Delta=916
            ETH=208
            Eacute=201
            Ecirc=202
            Egrave=200
            Epsilon=917
            Eta=919
            Euml=203
            Gamma=915
            Iacute=205
            Icirc=206
            Igrave=204
            Iota=921
            Iuml=207
            Kappa=922
            Lambda=923
            Mu=924
            Ntilde=209
            Nu=925
            OElig=338
            Oacute=211
            Ocirc=212
            Ograve=210
            Omega=937
            Omicron=927
            Oslash=216
            Otilde=213
            Ouml=214
            Phi=934
            Pi=928
            Prime=8243
            Psi=936
            Rho=929
            Scaron=352
            Sigma=931
            THORN=222
            Tau=932
            Theta=920
            Uacute=218
            Ucirc=219
            Ugrave=217
            Upsilon=933
            Uuml=220
            Xi=926
            Yacute=221
            Yuml=376
            Zeta=918
            aacute=225
            acirc=226
            acute=180
            aelig=230
            agrave=224
            alefsym=8501
            alpha=945
            amp=38
            and=8743
            ang=8736
            aring=229
            asymp=8776
            atilde=227
            auml=228
            bdquo=8222
            beta=946
            brvbar=166
            bull=8226
            cap=8745
            ccedil=231
            cedil=184
            cent=162
            chi=967
            circ=710
            clubs=9827
            cong=8773
            copy=169
            crarr=8629
            cup=8746
            curren=164
            dArr=8659
            dagger=8224
            darr=8595
            deg=176
            delta=948
            diams=9830
            divide=247
            eacute=233
            ecirc=234
            egrave=232
            empty=8709
            emsp=8195
            ensp=8194
            epsilon=949
            equiv=8801
            eta=951
            eth=240
            euml=235
            euro=8364
            exist=8707
            fnof=402
            forall=8704
            frac12=189
            frac14=188
            frac34=190
            frasl=8260
            gamma=947
            ge=8805
            gt=62
            hArr=8660
            harr=8596
            hearts=9829
            hellip=8230
            iacute=237
            icirc=238
            iexcl=161
            igrave=236
            image=8465
            infin=8734
            int=8747
            iota=953
            iquest=191
            isin=8712
            iuml=239
            kappa=954
            lArr=8656
            lambda=955
            lang=9001
            laquo=171
            larr=8592
            lceil=8968
            ldquo=8220
            le=8804
            lfloor=8970
            lowast=8727
            loz=9674
            lrm=8206
            lsaquo=8249
            lsquo=8216
            lt=60
            macr=175
            mdash=8212
            micro=181
            middot=183
            minus=8722
            mu=956
            nabla=8711
            nbsp=160
            ndash=8211
            ne=8800
            ni=8715
            not=172
            notin=8713
            nsub=8836
            ntilde=241
            nu=957
            oacute=243
            ocirc=244
            oelig=339
            ograve=242
            oline=8254
            omega=969
            omicron=959
            oplus=8853
            or=8744
            ordf=170
            ordm=186
            oslash=248
            otilde=245
            otimes=8855
            ouml=246
            para=182
            part=8706
            permil=8240
            perp=8869
            phi=966
            pi=960
            piv=982
            plusmn=177
            pound=163
            prime=8242
            prod=8719
            prop=8733
            psi=968
            quot=34
            rArr=8658
            radic=8730
            rang=9002
            raquo=187
            rarr=8594
            rceil=8969
            rdquo=8221
            real=8476
            reg=174
            rfloor=8971
            rho=961
            rlm=8207
            rsaquo=8250
            rsquo=8217
            sbquo=8218
            scaron=353
            sdot=8901
            sect=167
            shy=173
            sigma=963
            sigmaf=962
            sim=8764
            spades=9824
            sub=8834
            sube=8838
            sum=8721
            sup=8835
            sup1=185
            sup2=178
            sup3=179
            supe=8839
            szlig=223
            tau=964
            there4=8756
            theta=952
            thetasym=977
            thinsp=8201
            thorn=254
            tilde=732
            times=215
            trade=8482
            uArr=8657
            uacute=250
            uarr=8593
            ucirc=251
            ugrave=249
            uml=168
            upsih=978
            upsilon=965
            uuml=252
            weierp=8472
            xi=958
            yacute=253
            yen=165
            yuml=255
            zeta=950
            zwj=8205
            zwnj=8204
            """
        return Dictionary(uniqueKeysWithValues: values.split(separator: "\n").compactMap { row in
            let pair = row.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let value = UInt32(pair[1]) else { return nil }
            return (String(pair[0]), value)
        })
    }()

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func encodeMinimalHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#x27;")
    }

    private static func hintHTML(_ s: String, fieldName: String) -> String {
        guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return s }
        let id = "hint" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return """
        <a class=hint href="#" onclick="this.style.display='none';document.getElementById('\(id)').style.display='block';return false;" draggable=false>\(escapeHTML(fieldName))</a>
        <div id="\(id)" class=hint style="display: none">\(s)</div>
        """
    }

    private enum RubyMode {
        case furigana
        case kana
        case kanji
    }

    private static func rubyField(_ value: String, mode: RubyMode) -> String {
        let normalized = value.replacingOccurrences(of: "&nbsp;", with: " ")
        guard let regex = try? NSRegularExpression(pattern: #" ?([^ >]+?)\[(.+?)\]"#) else { return normalized }
        var output = normalized
        let matches = regex.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)).reversed()
        for match in matches {
            guard let baseRange = Range(match.range(at: 1), in: output),
                  let readingRange = Range(match.range(at: 2), in: output),
                  let fullRange = Range(match.range, in: output) else { continue }
            let base = String(output[baseRange])
            let reading = String(output[readingRange])
            if reading.hasPrefix("sound:") { continue }
            let replacement: String
            switch mode {
            case .furigana:
                replacement = "<ruby><rb>\(base)</rb><rt>\(reading)</rt></ruby>"
            case .kana:
                replacement = reading
            case .kanji:
                replacement = base
            }
            output.replaceSubrange(fullRange, with: replacement)
        }
        return output
    }

    static func fieldMap(note: AnkiNote, notetype: AnkiNotetype, deckName: String = "") -> [String: String] {
        var map: [String: String] = [:]
        let values = note.fields
        for field in notetype.flds {
            let value = field.ord < values.count ? values[field.ord] : ""
            map[field.name] = value
        }
        map["Tags"] = map["Tags"] ?? note.tagList.joined(separator: " ")
        map["Type"] = map["Type"] ?? notetype.name
        map["Deck"] = map["Deck"] ?? deckName
        map["Subdeck"] = map["Subdeck"] ?? (deckName.components(separatedBy: "::").last ?? deckName)
        return map
    }

    static func addCardFields(to fields: inout [String: String], name: String, flag: Int, id: Int64, ordinal: Int) {
        fields["Card"] = fields["Card"] ?? name
        fields["CardFlag"] = fields["CardFlag"] ?? "flag\(flag & 7)"
        fields["CardID"] = fields["CardID"] ?? String(id)
        let cardNumberField = "c\(ordinal + 1)"
        fields[cardNumberField] = fields[cardNumberField] ?? "1"
    }
}
