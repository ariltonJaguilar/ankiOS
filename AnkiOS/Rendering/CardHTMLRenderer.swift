import Foundation

@MainActor
enum CardHTMLRenderer {
    enum Side { case question, answer }

    struct RenderedCard: Sendable {
        var html: String
        var sounds: [String]
        var hasTypeAnswer: Bool
        /// Visible text stripped of HTML — used as a native SwiftUI face so Liquid Glass never shows a blank card.
        var plainText: String
        /// Question-side text, without the sound marker.
        var questionText: String
        /// Text that appears only after the answer is revealed. Empty on the question side.
        var answerText: String
        /// True when the face is plain text (no images / complex markup) and can be shown natively.
        var prefersNativeFace: Bool
    }

    static func renderCard(
        note: AnkiNote,
        card: AnkiCard,
        notetype: AnkiNotetype,
        side: Side,
        mediaBase: URL,
        typedAnswer: String? = nil,
        deckName: String = "",
        /// When true, {{type:Field}} becomes a marker (native SwiftUI field handles typing).
        omitTypeInput: Bool = false
    ) -> RenderedCard {
        guard let tmpl = notetype.tmpls.first(where: { $0.ord == card.ord }) ?? notetype.tmpls.first else {
            return RenderedCard(
                html: "<p>Missing template</p>",
                sounds: [],
                hasTypeAnswer: false,
                plainText: "Template ausente",
                questionText: "Template ausente",
                answerText: "",
                prefersNativeFace: true
            )
        }

        var fields = TemplateEngine.fieldMap(note: note, notetype: notetype, deckName: deckName)
        fields["Card"] = tmpl.name

        let hasTypeAnswer = TemplateEngine.templateHasTypeAnswer(tmpl.qfmt)
            || TemplateEngine.templateHasTypeAnswer(tmpl.afmt)

        let clozeOrd = notetype.isCloze ? card.ord : nil
        let front = TemplateEngine.render(
            template: tmpl.qfmt,
            fields: fields,
            frontSide: nil,
            clozeOrd: clozeOrd,
            questionSide: true,
            typedAnswer: nil,
            omitTypeInput: omitTypeInput || hasTypeAnswer
        )
        var body: String
        switch side {
        case .question:
            body = front
        case .answer:
            body = TemplateEngine.render(
                template: tmpl.afmt,
                fields: fields,
                frontSide: front,
                clozeOrd: clozeOrd,
                questionSide: false,
                typedAnswer: typedAnswer,
                omitTypeInput: omitTypeInput || hasTypeAnswer
            )
        }

        // If the template was only {{type:…}}, surface a prompt field so the card isn't blank.
        let hasRichFace = body.lowercased().contains("<img")
            || body.contains("io-mask")
            || Self.containsMath(body)
        if Self.visibleText(body).isEmpty && !hasRichFace {
            if let prompt = Self.fallbackPrompt(fields: fields, notetype: notetype, hasTypeAnswer: hasTypeAnswer) {
                body = "<div class=\"prompt\">\(prompt)</div>" + (body.isEmpty ? "" : body)
            }
        }

        let questionPlain = Self.visibleText(front)
        let answerPlain: String
        let soundSource: String
        switch side {
        case .question:
            answerPlain = ""
            soundSource = front
        case .answer:
            if let split = Self.splitAnswer(body) {
                answerPlain = Self.visibleText(split.answer)
                soundSource = front + split.answer
            } else {
                let combined = Self.visibleText(body)
                if combined.hasPrefix(questionPlain) {
                    answerPlain = String(combined.dropFirst(questionPlain.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else if combined == questionPlain {
                    answerPlain = ""
                } else {
                    answerPlain = combined
                }
                soundSource = front + body
            }
        }

        let uniqueSounds = Array(NSOrderedSet(array: MediaStore.soundFiles(in: soundSource))) as? [String] ?? []
        let plain = [questionPlain, answerPlain]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let prefersNative = Self.prefersNativeFace(body: body, plain: plain.isEmpty ? questionPlain : plain)
        let html = wrap(body: body, css: notetype.css, mediaBase: mediaBase)
        return RenderedCard(
            html: html,
            sounds: uniqueSounds,
            hasTypeAnswer: hasTypeAnswer,
            plainText: plain.isEmpty ? " " : plain,
            questionText: questionPlain,
            answerText: answerPlain,
            prefersNativeFace: prefersNative || (!uniqueSounds.isEmpty && plain.count <= 80 && !body.lowercased().contains("<img"))
        )
    }

    /// Anki marks the answer with `<hr id=answer>`.
    private static func splitAnswer(_ html: String) -> (front: String, answer: String)? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<hr\b[^>]*\bid\s*=\s*['\"]?answer['\"]?[^>]*>"#,
            options: [.caseInsensitive]
        ),
        let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
        let range = Range(match.range, in: html) else { return nil }
        return (String(html[..<range.lowerBound]), String(html[range.upperBound...]))
    }

    /// Simple kana / short prompts: native Text is more reliable than WKWebView on tinted glass.
    private static func prefersNativeFace(body: String, plain: String) -> Bool {
        guard !plain.isEmpty else { return false }
        let lower = body.lowercased()
        if lower.contains("<img") { return false }
        if lower.contains("<svg") { return false }
        if lower.contains("io-mask") { return false }
        if containsMath(body) { return false }
        if lower.contains("class=\"cloze\"") || lower.contains("class='cloze'") { return false }
        if lower.contains("class=\"typegood\"") || lower.contains("class=\"typebad\"") { return false }
        if lower.contains("<table") { return false }
        // Sound-only chrome is fine natively; ▶ markers don't need WebView.
        return plain.count <= 80
    }

    private static func visibleText(_ html: String) -> String {
        html
            .replacingOccurrences(of: #"<div class="sound"[^>]*>[\s\S]*?</div>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "▶", with: "")
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prefer Front / Expression / Text; skip the field that is typed.
    private static func fallbackPrompt(fields: [String: String], notetype: AnkiNotetype, hasTypeAnswer: Bool) -> String? {
        let typeField = TemplateEngine.typeAnswerFieldName(in: notetype.tmpls.map(\.qfmt).joined())
        let preferred = ["Front", "Expression", "Text", "Kanji", "Character", "Prompt", "Question"]
        for name in preferred {
            if name == typeField { continue }
            if let v = fields[name], !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return v
            }
        }
        for field in notetype.flds {
            if field.name == typeField { continue }
            if let v = fields[field.name], !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return v
            }
        }
        // Last resort: show typed field's sibling or any content.
        if let typeField, let v = fields[typeField], !v.isEmpty, !hasTypeAnswer {
            return v
        }
        return nil
    }

    private static func wrap(body: String, css: String, mediaBase: URL) -> String {
        let zoom = (CollectionStore.shared.conf["cardZoom"] as? Double) ?? 1.0
        let fontSize = Int((42.0 * zoom).rounded())
        return """
        <!DOCTYPE html>
        <html class="nightMode night_mode">
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <base href="\(mediaBase.absoluteString)/">
        <style>
        /* Note-type CSS first… */
        \(css)
        /* …then force readable colors on dark Liquid Glass (Anki templates often use color:black). */
        html, body {
          margin: 0 !important; padding: 0 !important;
          width: 100% !important; height: 100% !important;
          background: transparent !important;
          color: #f2fafb !important;
          -webkit-text-fill-color: #f2fafb !important;
          font-family: -apple-system, BlinkMacSystemFont, 'Hiragino Sans', 'Hiragino Kaku Gothic ProN', 'SF Pro Text', sans-serif;
        }
        .card, .card *:not(input):not(textarea) {
          background-color: transparent !important;
          color: #f2fafb !important;
          -webkit-text-fill-color: #f2fafb !important;
        }
        .card {
          background: transparent !important;
          padding: 36px 20px !important;
          font-size: \(fontSize)px !important;
          line-height: 1.35 !important;
          text-align: center !important;
          min-height: 180px;
          box-sizing: border-box;
          display: flex;
          flex-direction: column;
          align-items: center;
          justify-content: flex-start;
          padding-top: 48px !important;
        }
        .card .prompt { font-size: 1.15em; font-weight: 600; }
        .card a { color: #7eeadf !important; -webkit-text-fill-color: #7eeadf !important; }
        img { max-width: 100%; height: auto; }
        hr#answer { border: none; border-top: 1px solid rgba(255,255,255,0.28); margin: 18px 0; width: 100%; }
        .cloze { color: #5eead4 !important; -webkit-text-fill-color: #5eead4 !important; font-weight: 700; }
        .nightMode, .night_mode { color: #f2fafb !important; }
        input.typeans, textarea.typeans { display: none !important; }
        .typeGood { color: #4ade80 !important; -webkit-text-fill-color: #4ade80 !important; font-weight: 700; }
        .typeBad { color: #f87171 !important; -webkit-text-fill-color: #f87171 !important; font-weight: 700; }
        .mathjax, .mathjax * { color: #f2fafb !important; -webkit-text-fill-color: #f2fafb !important; }
        .io-stage { position: relative !important; display: inline-block !important; max-width: 100% !important; }
        .io-mask { box-sizing: border-box !important; }
        .io-mask.io-hidden { display: none !important; }
        .io-mask.io-covered { background-color: #f5d90a !important; border: 2px solid #111 !important; }
        .io-mask.io-revealed { background-color: transparent !important; border: 2px solid #5eead4 !important; }
        .io-mask[data-shape="ellipse"] { border-radius: 50% !important; }
        </style>
        </head>
        <body class="nightMode night_mode">
        <div class="card">
        \(Self.normalizeLatex(body))
        </div>
        \(Self.containsOcclusion(body) ? Self.occlusionScript : "")
        </body>
        </html>
        """
    }

    private static func containsMath(_ html: String) -> Bool {
        html.contains("\\(") || html.contains("\\[") || html.contains("[$$]")
            || html.contains("[$]") || html.contains("[latex]") || html.contains("anki-mathjax")
    }

    private static func containsOcclusion(_ html: String) -> Bool {
        html.contains("io-mask")
    }

    private static let occlusionScript = """
    <script>
    (function(){
      function layout(){
        var img = document.querySelector('.card img');
        var masks = Array.prototype.slice.call(document.querySelectorAll('.io-mask'));
        if (!img || !masks.length || !img.clientWidth) return;
        var stage = img.parentElement;
        if (!stage || !stage.classList.contains('io-stage')) {
          stage = document.createElement('div');
          stage.className = 'io-stage';
          img.parentNode.insertBefore(stage, img);
          stage.appendChild(img);
          masks.forEach(function(m){ stage.appendChild(m); });
        }
        var w = img.clientWidth, h = img.clientHeight;
        masks.forEach(function(el){
          var left = parseFloat(el.getAttribute('data-left')) || 0;
          var top = parseFloat(el.getAttribute('data-top')) || 0;
          var width = parseFloat(el.getAttribute('data-width')) || 0;
          var height = parseFloat(el.getAttribute('data-height')) || 0;
          el.style.position = 'absolute';
          el.style.left = (left * w) + 'px';
          el.style.top = (top * h) + 'px';
          var pw = width, ph = height, pl = left, pt = top;
          var points = el.getAttribute('data-points') || '';
          if (el.getAttribute('data-shape') === 'polygon' && points) {
            var xs = [], ys = [];
            points.trim().split(/\\s+/).forEach(function(pair){
              var xy = pair.split(',');
              var x = parseFloat(xy[0]), y = parseFloat(xy[1]);
              if (!isNaN(x) && !isNaN(y)) { xs.push(x); ys.push(y); }
            });
            if (xs.length) {
              pl = Math.min.apply(null, xs); pt = Math.min.apply(null, ys);
              pw = Math.max.apply(null, xs) - pl; ph = Math.max.apply(null, ys) - pt;
              var clip = points.trim().split(/\\s+/).map(function(pair){
                var xy = pair.split(',');
                var x = ((parseFloat(xy[0]) - pl) / (pw || 1)) * 100;
                var y = ((parseFloat(xy[1]) - pt) / (ph || 1)) * 100;
                return x + '% ' + y + '%';
              }).join(',');
              el.style.clipPath = 'polygon(' + clip + ')';
            }
          }
          el.style.left = (pl * w) + 'px';
          el.style.top = (pt * h) + 'px';
          el.style.width = (pw * w) + 'px';
          el.style.height = (ph * h) + 'px';
        });
        if (!document.getElementById('answer') || document.getElementById('io-toggle')) return;
        var button = document.createElement('button');
        button.id = 'io-toggle';
        button.type = 'button';
        button.textContent = 'Alternar máscaras';
        button.style.marginTop = '12px';
        stage.parentNode.insertBefore(button, stage.nextSibling);
        button.addEventListener('click', function(){
          stage.classList.toggle('io-show-all');
          var show = stage.classList.contains('io-show-all');
          masks.forEach(function(el){
            if (show) {
              el.classList.remove('io-hidden');
              if (!el.classList.contains('io-revealed')) el.classList.add('io-covered');
            }
          });
        });
      }
      window.addEventListener('load', layout);
      var img = document.querySelector('.card img');
      if (img) img.addEventListener('load', layout);
      setTimeout(layout, 40);
    })();
    </script>
    """

    private static func normalizeLatex(_ html: String) -> String {
        var s = html
        if let regex = try? NSRegularExpression(
            pattern: #"<anki-mathjax\b([^>]*)>([\s\S]*?)</anki-mathjax>"#,
            options: [.caseInsensitive]
        ) {
            let matches = regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed()
            for match in matches {
                guard let attrR = Range(match.range(at: 1), in: s),
                      let bodyR = Range(match.range(at: 2), in: s),
                      let full = Range(match.range, in: s) else { continue }
                let attrs = String(s[attrR]).lowercased()
                let body = String(s[bodyR])
                let display = attrs.contains("block") || attrs.contains("display")
                s.replaceSubrange(full, with: display ? "\\[\(body)\\]" : "\\(\(body)\\)")
            }
        }
        s = s.replacingOccurrences(of: "[latex]", with: "\\[")
        s = s.replacingOccurrences(of: "[/latex]", with: "\\]")
        s = s.replacingOccurrences(of: "[$$]", with: "\\[")
        s = s.replacingOccurrences(of: "[/$$]", with: "\\]")
        s = s.replacingOccurrences(of: "[$]", with: "\\(")
        s = s.replacingOccurrences(of: "[/$]", with: "\\)")
        return s
    }
}
