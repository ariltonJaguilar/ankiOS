import Foundation
import CryptoKit
#if !ANKIOS_PARITY_HARNESS && !WIDGET_EXTENSION
import AnkiBackend
#endif
#if os(iOS)
import UIKit
#endif

@MainActor
enum CardHTMLRenderer {
    enum Side: Equatable { case question, answer }

    struct RenderedCard: Sendable {
        var html: String
        var sounds: [String]
        var speech: [SpeechRequest]
        var questionSounds: [String]
        var answerSounds: [String]
        var questionSpeech: [SpeechRequest]
        var answerSpeech: [SpeechRequest]
        var questionPlayback: [PlaybackItem]
        var answerPlayback: [PlaybackItem]
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

    struct SpeechRequest: Hashable, Sendable {
        var language: String
        var text: String
        var speed: Float
        var voices: [String]
    }

    enum PlaybackItem: Hashable, Sendable {
        case file(String)
        case speech(SpeechRequest)
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
        omitTypeInput: Bool = false,
        nightMode: Bool = true
    ) -> RenderedCard {
        guard let tmpl = notetype.tmpls.first(where: { $0.ord == card.ord }) ?? notetype.tmpls.first else {
            return RenderedCard(
                html: "<p>Missing template</p>",
                sounds: [],
                speech: [],
                questionSounds: [],
                answerSounds: [],
                questionSpeech: [],
                answerSpeech: [],
                questionPlayback: [],
                answerPlayback: [],
                hasTypeAnswer: false,
                plainText: "Template ausente",
                questionText: "Template ausente",
                answerText: "",
                prefersNativeFace: true
            )
        }

        var fields = TemplateEngine.fieldMap(note: note, notetype: notetype, deckName: deckName)
        TemplateEngine.addCardFields(
            to: &fields,
            name: tmpl.name,
            flag: card.flags,
            id: card.id,
            ordinal: card.ord
        )

        let hasTypeAnswer = TemplateEngine.templateHasTypeAnswer(tmpl.qfmt)
            || TemplateEngine.templateHasTypeAnswer(tmpl.afmt)

        let clozeOrd = notetype.isCloze ? card.ord : nil
        var front = TemplateEngine.render(
            template: tmpl.qfmt,
            fields: fields,
            frontSide: nil,
            clozeOrd: clozeOrd,
            questionSide: true,
            typedAnswer: nil,
            omitTypeInput: omitTypeInput || hasTypeAnswer
        )
        var emptyFrontMessage: String?
        if TemplateEngine.validationError(template: tmpl.qfmt, fields: fields, questionSide: true) == nil {
            if notetype.isCloze {
                if !ClozeHelper.ords(in: Array(fields.values)).contains(card.ord) {
                    emptyFrontMessage = "<div>Nenhuma omissão \u{2068}\(card.ord + 1)\u{2069} encontrada no cartão.\nAdicione uma omissão de palavras ou use a ferramenta 'Cartas Vazias'.<br><a href='https://docs.ankiweb.net/templates/errors.html#no-cloze-filter-on-cloze-note-type'>Mais informações</a></div>"
                }
            } else {
                let nonemptyFields = Set(fields.compactMap { key, value in
                    CollectionStore.ankiFieldIsEmpty(value) ? nil : key
                })
                if !CollectionStore.templateRendersWithFields(
                    tmpl.qfmt, nonemptyFields: nonemptyFields,
                    knownFields: Set(fields.keys).union(["FrontSide"])
                ) {
                    emptyFrontMessage = "<div>A frente deste cartão está em branco.<br><a href='https://docs.ankiweb.net/templates/errors.html#front-of-card-is-blank'>Mais informações</a></div>"
                }
            }
        }
        if let emptyFrontMessage { front += emptyFrontMessage }
        let body: String
        switch side {
        case .question:
            body = front
        case .answer:
            body = emptyFrontMessage ?? TemplateEngine.render(
                template: tmpl.afmt,
                fields: fields,
                frontSide: front,
                clozeOrd: clozeOrd,
                questionSide: false,
                typedAnswer: typedAnswer,
                omitTypeInput: omitTypeInput || hasTypeAnswer
            )
        }

        let questionPlain = Self.visibleText(front)
        let answerPlain: String
        let soundSource: String
        let answerOnlySource: String
        switch side {
        case .question:
            answerPlain = ""
            soundSource = front
            answerOnlySource = front
        case .answer:
            answerOnlySource = TemplateEngine.render(
                template: tmpl.afmt,
                fields: fields,
                frontSide: nil,
                clozeOrd: clozeOrd,
                questionSide: false,
                typedAnswer: typedAnswer,
                omitTypeInput: omitTypeInput || hasTypeAnswer
            )
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

        let sounds = MediaStore.soundFiles(in: soundSource)
        let speech = speechRequests(in: body)
        let questionSounds = MediaStore.soundFiles(in: front)
        let answerSounds = side == .answer
            ? MediaStore.soundFiles(in: answerOnlySource)
            : []
        let questionSpeech = speechRequests(in: front)
        let answerSpeech = side == .answer ? speechRequests(in: answerOnlySource) : []
        let questionPlayback = playbackItems(in: front)
        let answerPlayback = side == .answer ? playbackItems(in: answerOnlySource) : []
        let plain = [questionPlain, answerPlain]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let html = wrap(
            body: body,
            css: notetype.css,
            mediaBase: mediaBase,
            side: side,
            latexSVG: notetype.latexsvg,
            latexPre: notetype.latexPre,
            latexPost: notetype.latexPost,
            nightMode: nightMode
        )
        return RenderedCard(
            html: html,
            sounds: sounds,
            speech: speech,
            questionSounds: questionSounds,
            answerSounds: answerSounds,
            questionSpeech: questionSpeech,
            answerSpeech: answerSpeech,
            questionPlayback: questionPlayback,
            answerPlayback: answerPlayback,
            hasTypeAnswer: hasTypeAnswer,
            plainText: plain.isEmpty ? " " : plain,
            questionText: questionPlain,
            answerText: answerPlain,
            prefersNativeFace: false
        )
    }

    private static func speechRequests(in html: String) -> [SpeechRequest] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<anki-tts\s+data-lang="([^"]+)"\s+data-speed="([^"]+)"\s+data-voices="([^"]*)"\s+data-text="([^"]*)">"#
        ) else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            speechRequest(in: html, match: $0)
        }
    }

    private static func playbackItems(in html: String) -> [PlaybackItem] {
        var indexed: [(location: Int, item: PlaybackItem)] = []
        if let soundRegex = try? NSRegularExpression(
            pattern: #"<div\s+class="sound"\s+data-file="([^"]+)"[^>]*>[\s\S]*?</div>"#
        ) {
            for match in soundRegex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range(at: 1), in: html) else { continue }
                indexed.append((match.range.location, .file(String(html[range]))))
            }
        }
        if let speechRegex = try? NSRegularExpression(
            pattern: #"<anki-tts\s+data-lang="([^"]+)"\s+data-speed="([^"]+)"\s+data-voices="([^"]*)"\s+data-text="([^"]*)">"#
        ) {
            for match in speechRegex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let request = speechRequest(in: html, match: match) else { continue }
                indexed.append((match.range.location, .speech(request)))
            }
        }
        return indexed.sorted { $0.location < $1.location }.map { $0.item }
    }

    private static func speechRequest(in html: String, match: NSTextCheckingResult) -> SpeechRequest? {
        guard let languageRange = Range(match.range(at: 1), in: html),
              let speedRange = Range(match.range(at: 2), in: html),
              let voicesRange = Range(match.range(at: 3), in: html),
              let dataRange = Range(match.range(at: 4), in: html),
              let data = Data(base64Encoded: String(html[dataRange])),
              let rawText = String(data: data, encoding: .utf8) else { return nil }
        let voicesData = Data(base64Encoded: String(html[voicesRange])) ?? Data()
        let voices = (try? JSONDecoder().decode([String].self, from: voicesData)) ?? []
        let text = visibleText(rawText)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
        guard !text.isEmpty else { return nil }
        return SpeechRequest(
            language: String(html[languageRange]),
            text: text,
            speed: Float(html[speedRange]) ?? 1,
            voices: voices
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

    private static func visibleText(_ html: String) -> String {
        let withoutNonVisibleCode = html.replacingOccurrences(
            of: #"(?is)<!--.*?-->|<script\b[^>]*>.*?</script>|<style\b[^>]*>.*?</style>"#,
            with: " ",
            options: .regularExpression
        )
        let stripped = withoutNonVisibleCode
            .replacingOccurrences(of: #"<div class="sound"[^>]*>[\s\S]*?</div>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "▶", with: "")
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return (TemplateEngine.decodeHTMLEntities(stripped) ?? stripped)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wrap(
        body: String,
        css: String,
        mediaBase: URL,
        side: Side,
        latexSVG: Bool,
        latexPre: String,
        latexPost: String,
        nightMode: Bool
    ) -> String {
        let zoom = (CollectionStore.shared.conf["cardZoom"] as? Double) ?? 1.0
        let hideAudioPlayButtons = CollectionStore.shared.conf["hideAudioPlayButtons"] as? Bool ?? false
        #if os(macOS)
        let missedAnswerStyle = ".typeMissed { color: #aaa !important; }"
        let platformClasses = "mac"
        #else
        let missedAnswerStyle = ""
        let deviceClass = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let platformClasses = "mobile \(deviceClass)"
        #endif
        let sideName: String
        let themeClasses = nightMode ? "nightMode night_mode" : ""
        switch side {
        case .question: sideName = "question"
        case .answer: sideName = "answer"
        }
        let extraction = AnkiLatexMarkup.extract(in: body, svg: latexSVG)
        var renderedBody = extraction.html
        #if os(macOS) && !WIDGET_EXTENSION
        let renderLatex = CollectionStore.shared.conf["renderLatex"] as? Bool ?? false
        let errors = AnkiLatexImageGenerator.renderMissing(
            extraction.assets.map {
                AnkiLatexRenderTask(asset: $0, header: latexPre, footer: latexPost, svg: latexSVG)
            },
            mediaRoot: mediaBase,
            enabled: renderLatex
        )
        renderedBody += errors.map { "<br>\($0)" }.joined()
        #endif
        return """
        <!DOCTYPE html>
        <html class="\(themeClasses) \(platformClasses)">
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <base href="\(mediaBase.absoluteString)/">
        \(Self.containsOcclusion(body) ? Self.imageOcclusionBridge : "")
        <style>
        code#typeans { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        .typeGood { color: #0a0 !important; }
        .typeBad { color: #f00 !important; }
        \(missedAnswerStyle)
        \(css)
        html, body {
          margin: 0;
          min-height: 100%;
          background: transparent;
        }
        .ankios-card-frame {
          box-sizing: border-box;
          min-height: 100vh;
          padding: 8px;
          zoom: \(zoom);
        }
        img { max-width: 100%; height: auto; }
        .io-stage { position: relative !important; display: inline-block !important; max-width: 100% !important; }
        .io-mask { box-sizing: border-box !important; }
        .io-mask.io-hidden { display: none !important; }
        .io-mask.io-covered { background-color: var(--io-fill, #f5d90a) !important; border: 2px solid #111 !important; }
        .io-mask.io-revealed { background-color: transparent !important; border: 2px solid #5eead4 !important; }
        .io-mask[data-shape="ellipse"] { border-radius: 50% !important; }
        .io-mask[data-shape="text"] { background-color: #fff !important; color: var(--io-fill, #222) !important; white-space: pre-wrap; }
        \(hideAudioPlayButtons ? ".sound { display: none !important; }" : "")
        </style>
        </head>
        <body class="\(themeClasses) \(platformClasses)" data-side="\(sideName)">
        <div class="ankios-card-frame">
        <div class="card">
        \(Self.normalizeMathJax(renderedBody))
        </div>
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

    private static let imageOcclusionBridge = """
    <script>
    window.anki = window.anki || {};
    window.anki.imageOcclusion = window.anki.imageOcclusion || {};
    window.anki.imageOcclusion.setup = window.anki.imageOcclusion.setup || function(){};
    </script>
    """

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
          var shape = el.getAttribute('data-shape') || 'rect';
          var left = parseFloat(el.getAttribute('data-left')) || 0;
          var top = parseFloat(el.getAttribute('data-top')) || 0;
          var width = parseFloat(el.getAttribute('data-width')) || 0;
          var height = parseFloat(el.getAttribute('data-height')) || 0;
          if (shape === 'ellipse') {
            var rx = parseFloat(el.getAttribute('data-rx'));
            var ry = parseFloat(el.getAttribute('data-ry'));
            if (!isNaN(rx)) width = rx * 2;
            if (!isNaN(ry)) height = ry * 2;
          }
          el.style.position = 'absolute';
          el.style.left = (left * w) + 'px';
          el.style.top = (top * h) + 'px';
          var pw = width, ph = height, pl = left, pt = top;
          var points = el.getAttribute('data-points') || '';
          if (shape === 'polygon' && points) {
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
          var fill = el.getAttribute('data-fill');
          if (fill) el.style.setProperty('--io-fill', fill);
          if (shape === 'text') {
            el.textContent = el.getAttribute('data-text') || '';
            el.style.backgroundColor = '#fff';
            el.style.color = fill || '#222';
            el.style.display = 'flex';
            el.style.alignItems = 'center';
            el.style.justifyContent = 'center';
            var fontSize = parseFloat(el.getAttribute('data-font-size'));
            var scale = parseFloat(el.getAttribute('data-scale')) || 1;
            el.style.fontSize = ((isNaN(fontSize) ? 20 : fontSize * h) * scale) + 'px';
          }
          var angle = parseFloat(el.getAttribute('data-angle'));
          if (!isNaN(angle) && shape !== 'polygon') {
            el.style.transform = 'rotate(' + ((angle % 10000) * 0.036) + 'deg)';
            el.style.transformOrigin = 'center center';
          }
        });
        var button = document.getElementById('toggle') || document.getElementById('io-toggle');
        if (!button && document.getElementById('answer')) {
          button = document.createElement('button');
          button.id = 'io-toggle';
          button.type = 'button';
          button.textContent = 'Alternar máscaras';
          button.style.marginTop = '12px';
          stage.parentNode.insertBefore(button, stage.nextSibling);
        }
        if (!button) return;
        var hasOccludedInactive = masks.some(function(el){
          return el.getAttribute('data-occludeinactive') === '1';
        });
        if (!hasOccludedInactive) {
          button.style.display = 'none';
          return;
        }
        var originalStates = masks.map(function(el){
          return {
            hidden: el.classList.contains('io-hidden'),
            covered: el.classList.contains('io-covered'),
            revealed: el.classList.contains('io-revealed')
          };
        });
        button.addEventListener('click', function(){
          stage.classList.toggle('io-show-all');
          var show = stage.classList.contains('io-show-all');
          masks.forEach(function(el, index){
            if (show) {
              el.classList.remove('io-hidden');
              if (!el.classList.contains('io-revealed')) el.classList.add('io-covered');
            } else {
              el.classList.toggle('io-hidden', originalStates[index].hidden);
              el.classList.toggle('io-covered', originalStates[index].covered);
              el.classList.toggle('io-revealed', originalStates[index].revealed);
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

    private static func normalizeMathJax(_ html: String) -> String {
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
        return s
    }
}

struct AnkiLatexAsset: Hashable, Sendable {
    var filename: String
    var body: String
}

struct AnkiLatexExtraction: Sendable {
    var html: String
    var assets: [AnkiLatexAsset]
}

struct AnkiLatexRenderTask: Sendable {
    var asset: AnkiLatexAsset
    var header: String
    var footer: String
    var svg: Bool
}

enum AnkiLatexMarkup {
    static func replacing(in html: String, svg: Bool) -> String {
        extract(in: html, svg: svg).html
    }

    static func extract(in html: String, svg: Bool, expandClozes: Bool = false) -> AnkiLatexExtraction {
        #if !ANKIOS_PARITY_HARNESS && !WIDGET_EXTENSION
        var error: UnsafeMutablePointer<CChar>?
        let rendered = html.withCString { text in
            ankios_anki_extract_latex_details(text, svg ? 1 : 0, expandClozes ? 1 : 0, &error)
        }
        defer {
            if let error { ankios_anki_backend_free_string(error) }
        }
        if let rendered {
            defer { ankios_anki_backend_free_string(rendered) }
            if let data = String(cString: rendered).data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let outputHTML = payload["html"] as? String,
               let values = payload["latex"] as? [[String: String]] {
                let assets = values.compactMap { value -> AnkiLatexAsset? in
                    guard let filename = value["filename"], let body = value["body"] else { return nil }
                    return AnkiLatexAsset(filename: filename, body: body)
                }
                return AnkiLatexExtraction(html: outputHTML, assets: assets)
            }
        }
        #endif

        return extractWithSwift(in: html, svg: svg, expandClozes: expandClozes)
    }

    private static func extractWithSwift(in html: String, svg: Bool, expandClozes: Bool) -> AnkiLatexExtraction {
        if expandClozes && html.contains("{{c") && !containsLatex(html) {
            return AnkiLatexExtraction(html: "", assets: [])
        }
        let sources = expandClozes ? expandedLatexSources(in: html) : [html]
        var combinedHTML = ""
        var combinedAssets: [AnkiLatexAsset] = []
        for source in sources {
            let extraction = extractWithoutClozes(in: source, svg: svg)
            combinedHTML += extraction.html
            combinedAssets += extraction.assets
        }
        return AnkiLatexExtraction(html: combinedHTML, assets: combinedAssets)
    }

    private static func extractWithoutClozes(in source: String, svg: Bool) -> AnkiLatexExtraction {
        guard let regex = try? NSRegularExpression(
            pattern: #"\[latex\](.+?)\[/latex\]|\[\$\](.+?)\[/\$\]|\[\$\$\](.+?)\[/\$\$\]"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return AnkiLatexExtraction(html: source, assets: []) }
        var result = source
        var assets: [AnkiLatexAsset] = []
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let fullRange = Range(match.range, in: result) else { continue }
            let body: String
            if match.range(at: 1).location != NSNotFound, let range = Range(match.range(at: 1), in: source) {
                body = String(source[range])
            } else if match.range(at: 2).location != NSNotFound, let range = Range(match.range(at: 2), in: source) {
                body = "$\(source[range])$"
            } else if let range = Range(match.range(at: 3), in: source) {
                body = "\\begin{displaymath}\(source[range])\\end{displaymath}"
            } else {
                continue
            }
            let latex = stripHTML(body)
            let digest = Insecure.SHA1.hash(data: Data(latex.utf8)).map { String(format: "%02x", $0) }.joined()
            let extensionName = svg ? "svg" : "png"
            let filename = "latex-\(digest).\(extensionName)"
            let image = "<img class=latex alt=\"\(encodeAttribute(latex))\" src=\"\(filename)\">"
            result.replaceSubrange(fullRange, with: image)
            assets.append(AnkiLatexAsset(filename: filename, body: latex))
        }
        return AnkiLatexExtraction(html: result, assets: assets.reversed())
    }

    private static func containsLatex(_ text: String) -> Bool {
        text.range(of: #"\[latex\]|\[\$\]|\[\$\$\]"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func expandedLatexSources(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"\{\{c(\d+(?:,\d+)*)::(.*?)(?:::(.*?))?\}\}"#,
            options: [.dotMatchesLineSeparators]
        ) else { return [text] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let ordinals = Set(matches.flatMap { match -> [Int] in
            guard let range = Range(match.range(at: 1), in: text) else { return [] }
            return text[range].split(separator: ",").compactMap { Int($0) }
        }).sorted()
        guard !ordinals.isEmpty else { return [text] }
        return ordinals.flatMap { ordinal in
            [true, false].compactMap { question in
                revealClozes(in: text, matches: matches, ordinal: ordinal, question: question)
            }
        }
    }

    private static func revealClozes(
        in text: String,
        matches: [NSTextCheckingResult],
        ordinal: Int,
        question: Bool
    ) -> String? {
        var result = text
        var foundActive = false
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let ordRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text) else { continue }
            let ordinals = text[ordRange].split(separator: ",").compactMap { Int($0) }
            let body = String(text[bodyRange])
            let replacement: String
            if ordinals.contains(ordinal) {
                foundActive = true
                if question {
                    let hint = Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? "..."
                    replacement = "[\(hint)]"
                } else {
                    replacement = body
                }
            } else {
                replacement = body
            }
            result.replaceSubrange(fullRange, with: replacement)
        }
        return foundActive ? result : nil
    }

    private static func stripHTML(_ html: String) -> String {
        let lineBreaks = html.replacingOccurrences(
            of: #"<br( /)?>|<div>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        let tagPattern = #"<!--.*?-->|<style.*?>.*?</style>|<script.*?>.*?</script>|<.*?>"#
        let tagExpression = try? NSRegularExpression(
            pattern: tagPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        let fullRange = NSRange(lineBreaks.startIndex..<lineBreaks.endIndex, in: lineBreaks)
        let withoutTags = tagExpression?.stringByReplacingMatches(
            in: lineBreaks,
            range: fullRange,
            withTemplate: ""
        ) ?? lineBreaks
        return decodeEntities(withoutTags)
    }

    private static func decodeEntities(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-f]+|#\d+|[a-z][a-z0-9]+);"#, options: .caseInsensitive) else {
            return text
        }
        var result = text
        let entities: [String: String] = [
            "amp": "&", "nbsp": " ", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "copy": "©", "reg": "®", "trade": "™", "times": "×", "divide": "÷",
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "pi": "π", "sigma": "σ",
            "infin": "∞", "ne": "≠", "le": "≤", "ge": "≥", "sum": "∑", "radic": "√"
        ]
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[nameRange])
            let decoded: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(String.init)
            } else if name.hasPrefix("#") {
                decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map(String.init)
            } else {
                decoded = entities[name.lowercased()]
            }
            if let decoded { result.replaceSubrange(fullRange, with: decoded) }
        }
        return result
    }

    private static func encodeAttribute(_ text: String) -> String {
        var encoded = String()
        encoded.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 34: encoded += "&quot;"
            case 38: encoded += "&amp;"
            case 39: encoded += "&#x27;"
            case 60: encoded += "&lt;"
            case 62: encoded += "&gt;"
            default:
                let value = scalar.value
                let isASCIIAlphanumeric = (48...57).contains(value)
                    || (65...90).contains(value)
                    || (97...122).contains(value)
                if value < 256 && (value > 127 || !isASCIIAlphanumeric) {
                    encoded += String(format: "&#x%02X;", value)
                } else {
                    encoded.unicodeScalars.append(scalar)
                }
            }
        }
        return encoded
    }
}

#if os(macOS) && !WIDGET_EXTENSION
enum AnkiLatexImageGenerator {
    private enum RenderError: Error {
        case disabled
        case executableMissing(String)
        case commandFailed(String, String)
        case outputMissing(String)
        case message(String)

        var html: String {
            let message: String
            switch self {
            case .disabled:
                message = "La geração de LaTeX está desativada nas preferências."
            case .executableMissing(let executable):
                message = "Não foi possível executar \(executable). Verifique se LaTeX e dvipng/dvisvgm estão instalados."
            case .commandFailed(let executable, let log):
                let detail = log.isEmpty ? "" : " — \(log)"
                message = "Falha ao executar \(executable). Verifique se LaTeX e dvipng/dvisvgm estão instalados.\(detail)"
            case .outputMissing(let filename):
                message = "O comando LaTeX não criou \(filename)."
            case .message(let value):
                message = value
            }
            let escaped = message
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            return "<div class=latex-error>\(escaped)</div>"
        }
    }

    static func renderMissing(
        _ tasks: [AnkiLatexRenderTask],
        mediaRoot: URL,
        enabled: Bool,
        stopOnError: Bool = false
    ) -> [String] {
        guard !tasks.isEmpty else { return [] }
        let fileManager = FileManager.default
        var errors: [String] = []
        var rendered = Set<String>()
        for task in tasks {
            let asset = task.asset
            let destination = mediaRoot.appendingPathComponent(asset.filename)
            if fileManager.fileExists(atPath: destination.path) { continue }
            guard !rendered.contains(asset.filename) else { continue }
            guard enabled else { return errors + [RenderError.disabled.html] }
            do {
                try render(task, destination: destination)
                rendered.insert(asset.filename)
            } catch let error as RenderError {
                errors.append(error.html)
                if stopOnError { return errors }
            } catch {
                errors.append(RenderError.message(error.localizedDescription).html)
                if stopOnError { return errors }
            }
        }
        return errors
    }

    private static func render(_ task: AnkiLatexRenderTask, destination: URL) throws {
        let asset = task.asset
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("ankios-latex-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("tmp.tex")
        let document = "\(task.header)\n\(asset.body)\n\(task.footer)"
        try Data(document.utf8).write(to: sourceURL, options: .atomic)

        let outputName = task.svg ? "tmp.svg" : "tmp.png"
        let commands: [(String, [String])]
        if task.svg {
            commands = [
                ("latex", ["-interaction=nonstopmode", "tmp.tex"]),
                ("dvisvgm", ["--no-fonts", "--exact", "-Z", "2", "tmp.dvi", "-o", outputName])
            ]
        } else {
            commands = [
                ("latex", ["-interaction=nonstopmode", "tmp.tex"]),
                ("dvipng", ["-bg", "Transparent", "-D", "200", "-T", "tight", "tmp.dvi", "-o", outputName])
            ]
        }

        let environment = ProcessInfo.processInfo.environment
        let searchPath = ((environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/usr/texbin", "/Library/TeX/texbin"]).joined(separator: ":")
        let logURL = directory.appendingPathComponent("latex_log.txt")
        fileManager.createFile(atPath: logURL.path, contents: Data())
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }

        for (name, arguments) in commands {
            guard let executable = executable(named: name, searchPath: searchPath) else {
                throw RenderError.executableMissing(name)
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = directory
            var processEnvironment = environment
            processEnvironment["PATH"] = searchPath
            process.environment = processEnvironment
            process.standardOutput = log
            process.standardError = log
            do {
                try process.run()
            } catch {
                throw RenderError.executableMissing(name)
            }
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                try? log.synchronize()
                let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                throw RenderError.commandFailed(name, output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        let outputURL = directory.appendingPathComponent(outputName)
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw RenderError.outputMissing(outputName)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: outputURL).write(to: destination, options: .atomic)
    }

    private static func executable(named name: String, searchPath: String) -> URL? {
        for directory in searchPath.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
#endif
