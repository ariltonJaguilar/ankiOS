import XCTest

@MainActor
final class AnkiOSUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["ANKIOS_UI_TEST_SESSION"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.staticTexts["Baralhos"].firstMatch.waitForExistence(timeout: 30))
    }

    override func tearDown() async throws {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name
        tree.lifetime = .keepAlways
        add(tree)
        app.terminate()
    }

    private func activate(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        guard element.waitForExistence(timeout: 10) else {
            XCTFail("Elemento ausente: \(element)", file: file, line: line)
            return
        }
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func navigate(_ title: String) {
        #if os(macOS)
        activate(app.outlines.staticTexts[title].firstMatch)
        #else
        activate(app.tabBars.buttons[title])
        #endif
    }

    private func button(_ title: String) {
        let element = app.buttons[title].firstMatch
        reveal(element)
        activate(element)
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<8 {
            let scroll = app.scrollViews.firstMatch
            guard scroll.exists else { return }
            let navigationBottom = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : 0
            let visibleTop = max(scroll.frame.minY, navigationBottom)
            if element.exists && element.isHittable {
                if element.elementType != .textView
                    || (element.frame.minY >= visibleTop && element.frame.maxY <= scroll.frame.maxY) { return }
            }
            let towardTop = element.exists && element.frame.minY < visibleTop
            #if os(macOS)
            scroll.scroll(byDeltaX: 0, deltaY: towardTop ? 450 : -450)
            #else
            let top = max(scroll.frame.minY, navigationBottom) + 24
            let bottom = min(scroll.frame.maxY, app.frame.maxY - 100) - 24
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let upper = origin.withOffset(CGVector(dx: scroll.frame.minX + 10, dy: top))
            let lower = origin.withOffset(CGVector(dx: scroll.frame.minX + 10, dy: max(top + 40, bottom)))
            if towardTop { upper.press(forDuration: 0.05, thenDragTo: lower) }
            else { lower.press(forDuration: 0.05, thenDragTo: upper) }
            #endif
        }
    }

    private func enter(_ value: String, into element: XCUIElement) {
        reveal(element)
        #if os(iOS)
        if element.elementType == .textView {
            XCTAssertTrue(element.exists)
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).tap()
        } else {
            activate(element)
        }
        #else
        activate(element)
        #endif
        element.typeText(value)
        #if os(iOS)
        if app.buttons["Ocultar teclado"].exists { button("Ocultar teclado") }
        #endif
    }

    private func createDeck(_ name: String) {
        button("Ações dos baralhos")
        button("Novo baralho")
        enter(name, into: app.textFields["Nome"].firstMatch)
        button("Criar")
        XCTAssertTrue(app.buttons["deck.open.\(name)"].waitForExistence(timeout: 10))
        finishTutorialIfPresented()
    }

    private func addNote(front: String = "UI question", back: String = "UI answer") {
        navigate("Adicionar")
        if !app.textViews["field.source.Front"].firstMatch.exists { button("add.source") }
        enter(front, into: app.textViews["field.source.Front"].firstMatch)
        enter(back, into: app.textViews["field.source.Back"].firstMatch)
        button("add.submit")
        XCTAssertTrue(app.staticTexts["Nota adicionada."].waitForExistence(timeout: 10))
        finishTutorialIfPresented()
    }

    private func finishTutorialIfPresented() {
        guard app.buttons["Continuar"].waitForExistence(timeout: 3) else { return }
        for _ in 0..<6 {
            if app.buttons["Ir para os baralhos"].exists {
                button("Ir para os baralhos")
                return
            }
            button("Continuar")
        }
        XCTFail("O tutorial não foi concluído")
    }

    private func search(_ query: String) {
        let field = app.textFields["Busca (deck:, tag:, is:new…)"].firstMatch
        activate(field)
        #if os(macOS)
        field.typeKey("a", modifierFlags: .command)
        #else
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        if let value = field.value as? String, !value.hasPrefix("Busca (") {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        #endif
        field.typeText(query + "\n")
    }

    func testMainNavigation() {
        for title in ["Adicionar", "Painel", "Estatísticas", "Ferramentas", "Baralhos"] {
            navigate(title)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = title
            tree.lifetime = .keepAlways
            add(tree)
            switch title {
            case "Adicionar": XCTAssertTrue(app.buttons["add.submit"].exists)
            case "Painel": XCTAssertTrue(app.textFields["Busca (deck:, tag:, is:new…)"].exists)
            case "Estatísticas": XCTAssertTrue(app.staticTexts["Hoje"].exists)
            case "Ferramentas": XCTAssertTrue(app.staticTexts["AnkiWeb"].exists)
            default: XCTAssertTrue(app.buttons["deck.open.Default"].exists)
            }
        }
    }

    func testDeckCreationAndOptions() {
        createDeck("UI Parent::UI Child")
        activate(app.buttons["deck.options.UI Parent::UI Child"])
        XCTAssertTrue(app.staticTexts["Opções do baralho"].firstMatch.waitForExistence(timeout: 10)
                      || app.navigationBars["Opções do baralho"].exists)
        button("Duplicar preset")
        button("Salvar")
        XCTAssertTrue(app.buttons["deck.open.UI Parent::UI Child"].waitForExistence(timeout: 10))
        activate(app.buttons["deck.open.UI Parent::UI Child"])
        XCTAssertTrue(app.staticTexts["UI Child"].firstMatch.waitForExistence(timeout: 10))
    }

    func testAddSearchAndDuplicateWarning() {
        addNote()
        enter("UI question", into: app.textViews["field.source.Front"].firstMatch)
        button("add.submit")
        XCTAssertTrue(app.alerts["Nota possivelmente duplicada"].waitForExistence(timeout: 10))
        button("Cancelar")
        navigate("Painel")
        search("UI question")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "UI question")).firstMatch.waitForExistence(timeout: 10))
    }

    func testStudyAnswerAndUndo() {
        addNote()
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        button("Mostrar resposta")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "Resposta"
        tree.lifetime = .keepAlways
        add(tree)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        button("study.rating.3")
        button("Mais ▾")
        button("Desfazer")
        XCTAssertTrue(app.buttons["Mostrar resposta"].waitForExistence(timeout: 10))
        button("Mostrar resposta")
        XCTAssertTrue(app.webViews.staticTexts["UI answer"].firstMatch.waitForExistence(timeout: 10))
    }

    func testPreferencesPersistence() {
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let toggle = app.switches["Modo minimalista"].firstMatch
        reveal(toggle)
        activate(toggle)
        button("Salvar preferências")
        app.terminate()
        app.launch()
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let restored = app.switches["Modo minimalista"].firstMatch
        reveal(restored)
        XCTAssertEqual(restored.value as? String, "1")
    }

    func testCollectionMaintenance() {
        addNote()
        navigate("Ferramentas")
        button("Verificar banco de dados")
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 20))
        button("OK")
        button("Criar backup agora")
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 20))
        button("OK")
        button("Verificar mídia")
        XCTAssertTrue(app.buttons["Concluído"].waitForExistence(timeout: 20))
        button("Concluído")
    }

    func testNoteTypesAndTemplates() {
        button("Ações dos baralhos")
        button("Tipos de nota")
        button("Adicionar Basic (e invertido)")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "Tipos de nota"
        tree.lifetime = .keepAlways
        add(tree)
        let reversed = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Basic (and reversed)")).firstMatch
        XCTAssertTrue(reversed.waitForExistence(timeout: 10))
        activate(reversed)
        button("Adicionar campo")
        XCTAssertTrue(app.textFields.containing(NSPredicate(format: "value == %@", "Campo 3")).firstMatch.exists)
        button("Salvar")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "3 campos · 2 templates")).firstMatch.waitForExistence(timeout: 10))
    }

    func testProfileIsolationAndPersistence() {
        addNote()
        navigate("Ferramentas")
        button("Perfis")
        button("Novo perfil…")
        enter("UI Second", into: app.alerts.textFields["Nome"].firstMatch)
        button("Criar")
        XCTAssertTrue(app.staticTexts["UI Second"].firstMatch.waitForExistence(timeout: 15))
        navigate("Painel")
        search("UI question")
        XCTAssertTrue(app.staticTexts["Nenhum cartão"].waitForExistence(timeout: 10))
        navigate("Ferramentas")
        button("User 1")
        navigate("Painel")
        search("UI question")
        XCTAssertTrue(app.staticTexts["UI question"].firstMatch.waitForExistence(timeout: 10))
    }

    func testStatisticsPeriodsAndScope() {
        addNote()
        navigate("Estatísticas")
        for period in ["3 meses", "1 ano", "Todo o histórico", "1 mês"] {
            button(period)
            XCTAssertTrue(app.staticTexts["Hoje"].exists)
        }
        let retention = app.staticTexts["Retenção verdadeira"]
        reveal(retention)
        XCTAssertTrue(retention.exists)
    }

    func testDisconnectedSyncAndImportCancellation() {
        button("Opções de sincronização")
        button("Sincronizar com AnkiWeb")
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        button("OK")
        button("Ações dos baralhos")
        button("Importar CSV")
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Cancelar"])).firstMatch
        activate(cancel)
        XCTAssertTrue(app.buttons["deck.open.Default"].waitForExistence(timeout: 10))
    }

    func testBrowserTagDeleteAndUndo() {
        addNote()
        navigate("Painel")
        search("UI question")
        activate(app.staticTexts["UI question"].firstMatch)
        button("Ações ▾")
        button("Adicionar tag…")
        enter("ui-tag", into: app.alerts.textFields["tag"].firstMatch)
        button("OK")
        search("tag:ui-tag")
        XCTAssertTrue(app.staticTexts["UI question"].firstMatch.waitForExistence(timeout: 10))
        button("Ações ▾")
        button("Selecionar todos")
        button("Ações ▾")
        button("Apagar…")
        button("Apagar notas")
        XCTAssertTrue(app.staticTexts["Nenhum cartão"].waitForExistence(timeout: 10))
        button("Desfazer")
        XCTAssertTrue(app.staticTexts["UI question"].firstMatch.waitForExistence(timeout: 10))
    }

    func testAddDraftSurvivesNavigation() {
        navigate("Adicionar")
        button("add.source")
        enter("UI draft", into: app.textViews["field.source.Front"].firstMatch)
        button("add.preview")
        button("Fechar")
        navigate("Painel")
        navigate("Adicionar")
        XCTAssertEqual(app.textViews["field.source.Front"].firstMatch.value as? String, "UI draft")
    }

    func testLocalSyncLoginUploadIncrementalDownloadAndDisconnect() throws {
        guard let endpoint = ProcessInfo.processInfo.environment["ANKIOS_UI_SYNC_ENDPOINT"],
              URL(string: endpoint)?.host == "127.0.0.1" else {
            throw XCTSkip("Defina ANKIOS_UI_SYNC_ENDPOINT para um servidor Anki descartável em localhost")
        }
        addNote(front: "UI synced question", back: "UI synced answer")
        navigate("Ferramentas")
        loginToLocalSync(endpoint)
        button("Sincronizar agora")
        XCTAssertTrue(app.buttons["Enviar coleção local"].waitForExistence(timeout: 30))
        button("Cancelar")
        button("Sincronizar agora")
        button("Enviar coleção local")
        XCTAssertTrue(app.staticTexts["Coleção enviada ao AnkiWeb."].waitForExistence(timeout: 60))
        addNote(front: "UI incremental question", back: "UI incremental answer")
        navigate("Ferramentas")
        button("Sincronizar agora")
        XCTAssertTrue(app.staticTexts["Sincronização com AnkiWeb concluída."].waitForExistence(timeout: 60))
        button("Perfis")
        button("Novo perfil…")
        enter("UI Download", into: app.alerts.textFields["Nome"].firstMatch)
        button("Criar")
        XCTAssertTrue(app.staticTexts["UI Download"].firstMatch.waitForExistence(timeout: 15))
        #if os(macOS)
        app.typeKey("[", modifierFlags: .command)
        #else
        activate(app.navigationBars.buttons.element(boundBy: 0))
        #endif
        loginToLocalSync(endpoint)
        button("Sincronizar agora")
        button("Baixar coleção do AnkiWeb")
        XCTAssertTrue(app.staticTexts["Coleção baixada do AnkiWeb."].waitForExistence(timeout: 60))
        navigate("Painel")
        search("UI incremental question")
        XCTAssertTrue(app.staticTexts["UI incremental question"].firstMatch.waitForExistence(timeout: 10))
        navigate("Ferramentas")
        button("Desconectar conta")
        XCTAssertTrue(app.textFields["Usuário ou e-mail"].waitForExistence(timeout: 10))
    }

    private func loginToLocalSync(_ endpoint: String) {
        enter("ui-local", into: app.textFields["Usuário ou e-mail"].firstMatch)
        enter("ui-local-only", into: app.secureTextFields["Senha do AnkiWeb"].firstMatch)
        enter(endpoint, into: app.textFields["Servidor personalizado (opcional)"].firstMatch)
        button("Conectar ao AnkiWeb")
        XCTAssertTrue(app.buttons["Sincronizar agora"].waitForExistence(timeout: 30))
    }

    func testOpenOfficialPackageAndStudyImportedMedia() throws {
        let package = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "official", withExtension: "apkg"))
        app.open(package)
        button("Importar")
        finishTutorialIfPresented()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 30))
        button("OK")
        finishTutorialIfPresented()
        activate(app.buttons["deck.open.UI Imported"])
        button("Estudar agora")
        XCTAssertTrue(app.webViews.staticTexts["UI imported question"].firstMatch.waitForExistence(timeout: 15))
        button("Mostrar resposta")
        XCTAssertTrue(app.webViews.staticTexts["UI imported answer"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.webViews.images.firstMatch.exists)
    }
}
