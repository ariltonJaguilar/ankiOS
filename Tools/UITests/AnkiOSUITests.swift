import XCTest
#if os(iOS)
import CoreGraphics
import CoreImage
import GameController
import UIKit
#endif

@MainActor
final class AnkiOSUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["ANKIOS_UI_TEST_SESSION"] = UUID().uuidString
        configureTestAppEnvironment(app)
        app.launch()
        #if os(iOS)
        if app.buttons["Pular"].waitForExistence(timeout: 2) {
            finishTutorialIfPresented()
        }
        navigate("Baralhos")
        #endif
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

    private func configureTestAppEnvironment(_ application: XCUIApplication) {
        application.launchArguments = ["-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        let syncEndpoint = Bundle(for: Self.self).object(forInfoDictionaryKey: "ANKIOS_UI_SYNC_ENDPOINT") as? String
            ?? ProcessInfo.processInfo.environment["ANKIOS_UI_SYNC_ENDPOINT"]
        if let syncEndpoint, URL(string: syncEndpoint)?.host == "127.0.0.1" {
            application.launchEnvironment["ANKIOS_UI_SYNC_ENDPOINT"] = syncEndpoint
        }
    }

    #if os(iOS)
    private func openAnkiURL(_ url: URL) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let monitor = addUIInterruptionMonitor(withDescription: "Autorizar abertura de link AnkiOS") { alert in
            let openButton = alert.buttons["Abrir"].firstMatch
            guard openButton.exists else { return false }
            openButton.tap()
            return true
        }
        defer { removeUIInterruptionMonitor(monitor) }
        app.open(url)
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            let openButton = alert.buttons["Abrir"].firstMatch
            if openButton.exists { openButton.tap() }
        }
    }
    #endif

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

    private func setToggle(_ element: XCUIElement, to enabled: Bool, file: StaticString = #filePath, line: UInt = #line) {
        guard element.waitForExistence(timeout: 10) else {
            XCTFail("Elemento ausente: \(element)", file: file, line: line)
            return
        }
        if !element.isHittable {
            revealPreferenceElement(element)
        }
        guard element.isHittable else {
            XCTFail("Switch fora da área interativa: \(element)", file: file, line: line)
            return
        }
        guard let isEnabled = toggleValue(element) else {
            XCTFail("Estado de switch inesperado: \(element.value ?? "nil")", file: file, line: line)
            return
        }
        guard isEnabled != enabled else { return }
        #if os(iOS)
        element.coordinate(withNormalizedOffset: CGVector(dx: enabled ? 0.2 : 0.8, dy: 0.5)).tap()
        #else
        activate(element, file: file, line: line)
        #endif
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if toggleValue(element) == enabled { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Switch não alterou para \(enabled ? "1" : "0"): valor \(element.value ?? "nil")", file: file, line: line)
    }

    private func toggleValue(_ element: XCUIElement) -> Bool? {
        let rawValue = "\(element.value ?? "")".lowercased()
        switch rawValue {
        case "1", "true", "on": return true
        case "0", "false", "off": return false
        default: return nil
        }
    }

    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 10) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), app.debugDescription)
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: timeout), .completed, app.debugDescription)
    }

    private func navigate(_ title: String) {
        #if os(macOS)
        activate(app.outlines.staticTexts[title].firstMatch)
        #else
        let tab = app.tabBars.buttons[title].firstMatch
        if tab.exists {
            activate(tab)
            return
        }
        let visibleTab = app.buttons[title].firstMatch
        if visibleTab.exists {
            activate(visibleTab)
            return
        }
        let overflowTab = app.buttons.matching(
            NSPredicate(format: "label MATCHES[c] %@", "^(Mais|More|Mais abas|More Tabs)$")
        ).firstMatch
        if overflowTab.exists { activate(overflowTab) }
        let hiddenTab = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", title)
        ).firstMatch
        activate(hiddenTab)
        #endif
    }

    private func openDeckContextMenu(_ name: String) {
        let deck = app.buttons["deck.open.\(name)"].firstMatch
        XCTAssertTrue(deck.waitForExistence(timeout: 10), app.debugDescription)
        #if os(macOS)
        deck.rightClick()
        #else
        deck.press(forDuration: 1)
        #endif
    }

    private func button(_ title: String) {
        let actionTitle = title == "Preferências do AnkiOS" ? "Opções de estudo" : title
        let studyCategoryLink = app.descendants(matching: .any).matching(identifier: "settings.preferences.study").firstMatch
        let preferencesRouteWasOpened = title == "Preferências do AnkiOS" && !studyCategoryLink.exists
        prepareSettingsRoute(for: nil, label: actionTitle)
        if preferencesRouteWasOpened { return }
        #if os(iOS)
        if title == "Fechar" {
            let closeControl = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@ OR identifier == %@", title, title)
            ).firstMatch
            activate(closeControl)
            return
        }
        if title == "add.submit" {
            activate(identified(title))
            return
        }
        if title == "Salvar" && app.navigationBars["Opções do Baralho"].exists {
            activate(app.buttons[title].firstMatch)
            return
        }
        if title == "Apagar baralho" {
            let confirmationAction = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", title, title)
            ).firstMatch
            if confirmationAction.exists {
                activate(confirmationAction)
                return
            }
        }
        #endif
        #if os(macOS)
        let window = app.windows.firstMatch
        let windowButton = window.buttons[actionTitle].firstMatch
        let windowMenuButton = window.menuButtons[actionTitle].firstMatch
        let windowMenuItem = window.menuItems[actionTitle].firstMatch
        let regularButton = windowButton.exists ? windowButton : app.buttons[actionTitle].firstMatch
        let menuButton = windowMenuButton.exists ? windowMenuButton : app.menuButtons[actionTitle].firstMatch
        let menuItem = windowMenuItem.exists ? windowMenuItem : app.menuItems[actionTitle].firstMatch
        let element = regularButton.exists ? regularButton : menuButton.exists ? menuButton : menuItem
        #else
        let button = app.buttons[actionTitle].firstMatch
        let accessibleControl = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR identifier == %@", actionTitle, actionTitle)
        ).firstMatch
        let element = button.exists ? button : accessibleControl
        #endif
        reveal(element)
        activate(element)
    }

    @discardableResult
    private func menuButton(_ title: String, swipeDown: Bool = false, select: Bool = true) -> XCUIElement {
        #if os(macOS)
        let window = app.windows.firstMatch
        let windowButton = window.buttons[title].firstMatch
        let windowMenuButton = window.menuButtons[title].firstMatch
        let windowMenuItem = window.menuItems[title].firstMatch
        let regularButton = windowButton.exists ? windowButton : app.buttons[title].firstMatch
        let menuButton = windowMenuButton.exists ? windowMenuButton : app.menuButtons[title].firstMatch
        let menuItem = windowMenuItem.exists ? windowMenuItem : app.menuItems[title].firstMatch
        let element = regularButton.exists ? regularButton : menuButton.exists ? menuButton : menuItem
        #else
        let queryTitle = title.replacingOccurrences(of: "…", with: "")
        let element = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", queryTitle)
        ).firstMatch
        #endif
        for _ in 0..<8 {
            if element.exists && element.isHittable {
                if select { activate(element) }
                return element
            }
            if swipeDown, app.collectionViews.firstMatch.exists {
                app.collectionViews.firstMatch.swipeDown()
            } else if swipeDown {
                app.swipeDown()
            } else if app.scrollViews.containing(.menuItem, identifier: title).firstMatch.exists {
                let menuScroll = app.scrollViews.containing(.menuItem, identifier: title).firstMatch
                let towardTop = element.exists && element.frame.minY < menuScroll.frame.minY
                menuScroll.scroll(byDeltaX: 0, deltaY: towardTop ? 450 : -450)
            } else if app.collectionViews.count > 1 {
                let menuList = app.collectionViews.element(boundBy: 0)
                let visibleHeight = min(menuList.frame.height, app.frame.height * 0.56)
                let startY = (visibleHeight - 30) / menuList.frame.height
                let endY = 30 / menuList.frame.height
                let start = menuList.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
                let end = menuList.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
                start.press(forDuration: 0.05, thenDragTo: end)
            } else {
                app.swipeUp()
            }
        }
        if select { activate(element) }
        return element
    }

    private func identified(_ identifier: String) -> XCUIElement {
        prepareSettingsRoute(for: identifier, label: nil)
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func prepareSettingsRoute(for identifier: String?, label: String?) {
        let route: String?
        if let identifier {
            switch identifier {
            case "settings.scheduler.fsrs":
                route = "settings.section.scheduler"
            case "settings.database.check", "settings.media.check":
                route = "settings.section.maintenance"
            case let value where value.hasPrefix("settings.backup."):
                route = "settings.section.backups"
            case let value where value.hasPrefix("settings.export."):
                route = "settings.section.importExport"
            case "settings.noteTypes.manage", "settings.noteTypes.add":
                route = "settings.section.noteTypes"
            case "ankiweb.openLoginPanel":
                route = "settings.section.ankiweb"
            case let value where value.hasPrefix("preferences.notifications."):
                route = "settings.preferences.notifications"
            case "preferences.Tema", "preferences.Reduzir movimento", "preferences.Modo minimalista", "preferences.language":
                route = "settings.preferences.appearance"
            case let value where value.hasPrefix("preferences.Sincronizar") || value.hasPrefix("preferences.Na próxima sincronização"):
                route = "settings.preferences.sync"
            case "preferences.imageMaxDimension", "preferences.resizePastedImages":
                route = "settings.preferences.editing"
            case let value where value.hasPrefix("preferences.") && value != "preferences.save":
                route = "settings.preferences.study"
            default:
                route = nil
            }
        } else if let label {
            switch label {
            case "Importar .apkg, .colpkg ou Mnemosyne .db", "Importar CSV / texto":
                route = "settings.section.importExport"
            case "Verificar banco de dados", "Otimizar banco (VACUUM)", "Procurar duplicatas", "Verificar mídia":
                route = "settings.section.maintenance"
            case "Criar backup agora":
                route = "settings.section.backups"
            case "Opções de estudo":
                route = "settings.preferences.study"
            case "Sincronizar agora", "Desconectar conta", "Iniciar sessão", "Conectar ao AnkiWeb":
                route = "settings.section.ankiweb"
            case "Gerenciar tipos de nota", "Adicionar nota":
                route = "settings.section.noteTypes"
            case "Desocultar todos os cartões ocultos", "Remover cartões vazios":
                route = "settings.section.cards"
            default:
                route = nil
            }
        } else {
            route = nil
        }
        guard let route else { return }

        let target: XCUIElement
        if let identifier {
            target = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        } else if let label {
            target = app.buttons[label].firstMatch
        } else {
            return
        }
        if target.exists { return }

        for _ in 0..<4 {
            if app.navigationBars["Ferramentas"].exists { break }
            let back = app.navigationBars.buttons.firstMatch
            guard back.exists else { return }
            activate(back)
        }

        let section = app.descendants(matching: .any).matching(identifier: route).firstMatch
        guard section.exists else { return }
        reveal(section)
        if section.isHittable { activate(section) }
    }

    private func revealStudyToolAction(_ rawValue: String) -> XCUIElement {
        let action = identified("study.tools.action.\(rawValue)")
        XCTAssertTrue(action.waitForExistence(timeout: 10), app.debugDescription)
        let scroll = identified("study.tools.scroll")
        XCTAssertTrue(scroll.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<8 {
            if action.frame.minY < scroll.frame.minY {
                scroll.swipeDown()
            } else if action.frame.maxY > scroll.frame.maxY {
                scroll.swipeUp()
            } else {
                break
            }
        }
        XCTAssertTrue(action.isHittable, app.debugDescription)
        return action
    }

    private func studyProgress() -> XCUIElement {
        identified("study.progress")
    }

    private func waitForStudyProgress(prefix: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix),
            object: identified("study.progress")
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

#if os(iOS)
    private func waitForWidth(_ element: XCUIElement, timeout: TimeInterval, satisfies condition: (CGFloat) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(element.frame.width) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition(element.frame.width)
    }

    private func pinchUntilWidth(_ target: XCUIElement, observing element: XCUIElement, exceeds minimumWidth: CGFloat) -> Bool {
        for velocity in [CGFloat(1), 0.6, 0.3] {
            target.pinch(withScale: 1.6, velocity: velocity)
            if waitForWidth(element, timeout: 2, satisfies: { $0 > minimumWidth }) { return true }
        }
        return element.frame.width > minimumWidth
    }
#endif

    private func deckCounts(_ name: String) -> [String] {
        let deck = app.buttons["deck.open.\(name)"].firstMatch
        XCTAssertTrue(deck.waitForExistence(timeout: 10), app.debugDescription)
        return deck.label.split(separator: ",").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func browserDueValue(_ value: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", ": \(value)", ": \(value)")
        ).firstMatch
    }

    private func incrementStepper(_ stepper: XCUIElement, times: Int = 1) {
        #if os(macOS)
        for _ in 0..<times {
            stepper.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).click()
        }
        #else
        let increment = stepper.buttons.element(boundBy: 1)
        for _ in 0..<times { increment.tap() }
        #endif
    }

    private func selectLanguage(_ name: String) {
        #if os(iOS)
        let locale: String
        switch name {
        case "English (United States)": locale = "en-US"
        case "Português Brasileiro": locale = "pt-BR"
        default:
            XCTFail("Idioma de teste não definido: \(name)")
            return
        }
        app.launchEnvironment.removeValue(forKey: "LC_ALL")
        app.launchArguments = ["-AppleLanguages", "(\(locale))", "-AppleLocale", locale.replacingOccurrences(of: "-", with: "_")]
        #else
        let language = identified("preferences.language")
        reveal(language)
        activate(language)

        let option = app.buttons[name].firstMatch
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        let options = app.collectionViews.element(boundBy: app.collectionViews.count - 1)
        let scrollTowardLaterLanguages = name.hasPrefix("Português")
        for _ in 0..<10 {
            if option.exists && option.isHittable { break }
            if scrollTowardLaterLanguages { options.swipeUp() }
            else { options.swipeDown() }
        }
        activate(option)
        XCTAssertTrue(app.alerts["Idioma alterado"].waitForExistence(timeout: 5), app.debugDescription)
        button("OK")
        #endif
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<16 {
            #if os(iOS)
            let navigationBar = app.navigationBars.firstMatch
            let appVisibleTop = max(app.frame.minY, navigationBar.exists ? navigationBar.frame.maxY : 0)
            let appVisibleBottom = app.frame.maxY - 100
            if element.exists && element.isHittable
                && element.frame.minY >= appVisibleTop
                && element.frame.maxY <= appVisibleBottom { return }
            if element.exists && element.isHittable
                && element.frame.midY >= appVisibleTop
                && element.frame.midY <= appVisibleBottom { return }
            #endif
            let containingScroll = app.scrollViews.containing(element.elementType, identifier: element.identifier).firstMatch
            let scroll = containingScroll.exists ? containingScroll : app.scrollViews.firstMatch
            guard scroll.exists else { return }
            let navigationBottom = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : 0
            #if os(macOS)
            let visibleTop = max(scroll.frame.minY, navigationBottom)
            let visibleBottom = scroll.frame.maxY
            #else
            let visibleTop = max(containingScroll.exists ? scroll.frame.minY : app.frame.minY, navigationBottom)
            let visibleBottom = min(containingScroll.exists ? scroll.frame.maxY : app.frame.maxY, app.frame.maxY - 100)
            #endif
            let textViewCenterIsVisible = element.elementType == .textView
                && element.frame.midY >= visibleTop
                && element.frame.midY < visibleBottom
            if element.exists && element.isHittable
                && ((element.frame.minY >= visibleTop && element.frame.maxY <= visibleBottom)
                    || textViewCenterIsVisible) { return }
            let towardTop = element.exists && element.frame.minY < visibleTop
            #if os(macOS)
            scroll.scroll(byDeltaX: 0, deltaY: towardTop ? 450 : -450)
            #else
            let top = max(scroll.frame.minY, navigationBottom) + 24
            let bottom = min(scroll.frame.maxY, app.frame.maxY - 100) - 24
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let swipeX = scroll.frame.minX + min(40, scroll.frame.width / 2)
            let upper = origin.withOffset(CGVector(dx: swipeX, dy: top))
            let lower = origin.withOffset(CGVector(dx: swipeX, dy: max(top + 40, bottom)))
            if towardTop { upper.press(forDuration: 0.05, thenDragTo: lower) }
            else { lower.press(forDuration: 0.05, thenDragTo: upper) }
            #endif
        }
    }

    private func revealPreferenceElement(_ element: XCUIElement) {
        let scroll = app.scrollViews.firstMatch
        guard scroll.waitForExistence(timeout: 5) else {
            reveal(element)
            return
        }
        for _ in 0..<8 {
            let navigationBottom = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : 0
            if element.exists && element.isHittable
                && element.frame.minY >= navigationBottom
                && element.frame.maxY <= app.frame.maxY - 100 { return }
            #if os(iOS)
            let revealFromAbove = element.exists && element.frame.minY < navigationBottom
            let startY = revealFromAbove
                ? max(navigationBottom + 24, scroll.frame.minY + 180)
                : min(scroll.frame.maxY - 180, app.frame.maxY - 140)
            let endY = startY + (revealFromAbove ? 160 : -160)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let x = scroll.frame.minX + min(40, scroll.frame.width / 2)
            origin.withOffset(CGVector(dx: x, dy: startY)).press(
                forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: x, dy: endY))
            )
            #else
            if element.exists && element.frame.minY < navigationBottom { scroll.swipeDown() }
            else { scroll.swipeUp() }
            #endif
        }
        reveal(element)
    }

    private func enter(_ value: String, into element: XCUIElement) {
        reveal(element)
        #if os(iOS)
        if element.elementType == .textView {
            XCTAssertTrue(element.exists)
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            activate(element)
        }
        #else
        activate(element)
        #endif
        type(value, into: element)
    }

    private func type(_ value: String, into element: XCUIElement) {
        #if os(macOS)
        for character in value {
            if character.isASCII && character.isLetter {
                let key = String(character).lowercased()
                let modifiers: XCUIElement.KeyModifierFlags = character.isUppercase ? .shift : []
                element.typeKey(key, modifierFlags: modifiers)
            } else if character.isASCII && character.isNumber {
                element.typeKey(String(character), modifierFlags: [])
            } else if character == " " {
                element.typeKey(XCUIKeyboardKey.space, modifierFlags: [])
            } else {
                element.typeText(String(character))
            }
        }
        #else
        for character in value {
            element.typeText(String(character))
        }
        #endif
        #if os(iOS)
        let hideKeyboard = app.buttons["Ocultar teclado"].firstMatch
        if !app.alerts.firstMatch.exists && hideKeyboard.exists {
            activate(hideKeyboard)
        }
        #endif
    }

    private func createDeck(_ name: String) {
        navigate("Baralhos")
        activate(identified("decks.importActions"))
        activate(identified("decks.newDeck"))
        let nameField = app.textFields["Nome"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), app.debugDescription)
        enter(name, into: nameField)
        button("Criar")
        XCTAssertTrue(app.buttons["deck.open.\(name)"].waitForExistence(timeout: 10))
        finishTutorialIfPresented()
    }

    private func addNote(front: String = "UI question", back: String = "UI answer", tags: String = "", deckName: String? = nil) {
        navigate("Adicionar")
        if !app.textViews["field.source.Front"].firstMatch.exists { button("add.source") }
        if let deckName {
            activate(identified("add.deck"))
            button(deckName)
        }
        let frontEditor = app.textViews["field.source.Front"].firstMatch
        enterSourceField(front, named: "Front")
        XCTAssertEqual(frontEditor.value as? String, front)
        let backEditor = app.textViews["field.source.Back"].firstMatch
        enterSourceField(back, named: "Back")
        XCTAssertEqual(backEditor.value as? String, back)
        if !tags.isEmpty {
            let tagField = app.textFields["tags separadas por espaço"].firstMatch
            reveal(tagField)
            activate(tagField)
            if let value = tagField.value as? String,
               !value.isEmpty,
               value != "tags separadas por espaço" {
                tagField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
            }
            type(tags, into: tagField)
            if !app.alerts.firstMatch.exists && app.buttons["Ocultar teclado"].exists {
                button("Ocultar teclado")
            }
        }
        button("add.submit")
        XCTAssertTrue(app.staticTexts["Nota adicionada."].waitForExistence(timeout: 10))
        finishTutorialIfPresented()
    }

    private func enterSourceField(_ value: String, named name: String) {
        let editor = app.textViews["field.source.\(name)"].firstMatch
        reveal(editor)
        XCTAssertTrue(editor.exists, app.debugDescription)
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.exists, app.debugDescription)
        let navigationBottom = app.navigationBars.firstMatch.exists
            ? app.navigationBars.firstMatch.frame.maxY
            : app.frame.minY
        var visibleTop = max(scroll.frame.minY, navigationBottom + 8)
        var visibleBottom = min(scroll.frame.maxY - 8, app.frame.maxY - 200)
        for _ in 0..<8 {
            if editor.frame.minY >= visibleTop && editor.frame.maxY <= visibleBottom { break }
            if editor.frame.maxY > visibleBottom {
                scroll.swipeUp()
            } else {
                scroll.swipeDown()
            }
            visibleTop = max(scroll.frame.minY, navigationBottom + 8)
            visibleBottom = min(scroll.frame.maxY - 8, app.frame.maxY - 200)
        }
        visibleTop = max(editor.frame.minY, visibleTop)
        visibleBottom = min(editor.frame.maxY, visibleBottom)
        XCTAssertLessThan(visibleTop, visibleBottom, app.debugDescription)
        let tapY = ((visibleTop + visibleBottom) / 2 - editor.frame.minY) / editor.frame.height
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: tapY)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        type(value, into: editor)
    }

    private func finishTutorialIfPresented() {
        let skip = app.buttons["Pular"].firstMatch
        if skip.exists {
            let hittable = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isHittable == true"),
                object: skip
            )
            if XCTWaiter.wait(for: [hittable], timeout: 3) == .completed, skip.exists {
                skip.tap()
            }
            return
        }
        guard app.buttons["Continuar"].exists else { return }
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
        #if os(macOS)
        type(query, into: field)
        field.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        #else
        field.typeText(query + "\n")
        #endif
    }

    func testMainNavigation() throws {
#if os(iOS)
        let infoConsumerEnabled = Bundle(for: Self.self).object(forInfoDictionaryKey: "ANKIOS_UI_INFO_CONSUMER") as? String == "1"
        if infoConsumerEnabled {
            try verifyInfoForAddingConsumer()
            return
        }
#endif

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
            case "Ferramentas":
                XCTAssertTrue(identified("settings.section.ankiweb").exists, app.debugDescription)
                XCTAssertTrue(identified("settings.section.importExport").exists, app.debugDescription)
                XCTAssertFalse(app.textFields["Usuário ou e-mail"].exists, app.debugDescription)
                #if os(iOS)
                activate(identified("settings.section.importExport"))
                XCTAssertTrue(app.navigationBars["Importar e exportar"].exists, app.debugDescription)
                XCTAssertTrue(
                    app.staticTexts["Importe baralhos APKG, arquivos CSV e coleções. Exporte sua coleção, baralhos ou notas."].exists,
                    app.debugDescription
                )
                activate(app.navigationBars.buttons.firstMatch)
                #endif
            default: XCTAssertTrue(app.buttons["deck.open.Default"].exists)
            }
        }
        #if os(iOS)
        activate(app.buttons["decks.importActions"].firstMatch)
        activate(app.buttons["decks.sharedDeckList"].firstMatch)
        XCTAssertTrue(app.navigationBars["Baralhos compartilhados"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let sharedDeckPage = XCTAttachment(string: app.debugDescription)
        sharedDeckPage.name = "Shared Deck List in AnkiOS"
        sharedDeckPage.lifetime = .keepAlways
        add(sharedDeckPage)
        button("Fechar")

        let searchURL = URLComponents(string: "anki://x-callback-url/search")!
        var searchComponents = searchURL
        searchComponents.queryItems = [URLQueryItem(name: "query", value: "anki callback search")]
        openAnkiURL(searchComponents.url!)
        let searchField = app.textFields["Busca (deck:, tag:, is:new…)"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(searchField.value as? String, "anki callback search", app.debugDescription)

        var infoComponents = URLComponents(string: "anki://x-callback-url/infoForAdding")!
        infoComponents.queryItems = [
            URLQueryItem(name: "x-success", value: "https://example.invalid/anki-info-callback")
        ]
        let pasteboardChangeCount = UIPasteboard.general.changeCount
        openAnkiURL(infoComponents.url!)
        let allowInfo = app.buttons["Permitir"]
        XCTAssertTrue(allowInfo.waitForExistence(timeout: 10), app.debugDescription)
        activate(allowInfo)
        XCTAssertGreaterThan(UIPasteboard.general.changeCount, pasteboardChangeCount)
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10), safari.debugDescription)
        app.activate()

        let remoteMediaURL = Bundle(for: Self.self).object(forInfoDictionaryKey: "ANKIOS_UI_REMOTE_MEDIA_URL") as? String
        if let remoteMediaURL, remoteMediaURL.hasPrefix("https://"),
           let mediaURL = URL(string: remoteMediaURL) {
            let remoteBack = "UI remote media \(UUID().uuidString.prefix(8))"
            var remoteComponents = URLComponents(string: "anki://x-callback-url/addnote")!
            remoteComponents.queryItems = [
                URLQueryItem(name: "type", value: "Basic"),
                URLQueryItem(name: "deck", value: "Default"),
                URLQueryItem(name: "fldFront", value: mediaURL.absoluteString),
                URLQueryItem(name: "fldBack", value: remoteBack),
                URLQueryItem(name: "tags", value: "remote-media-parity"),
                URLQueryItem(name: "x-success", value: "https://example.invalid/anki-remote-media-callback")
            ]
            openAnkiURL(remoteComponents.url!)
            XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), safari.debugDescription)
            app.activate()
            navigate("Painel")
            search(remoteBack)
            let remoteResult = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", remoteBack))
            XCTAssertTrue(remoteResult.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        }

        safari.open(URL(string: "https://ankiweb.net/shared/info/537951643")!)
        XCTAssertTrue(safari.webViews.staticTexts["Hiragana and Katakana"].waitForExistence(timeout: 15), safari.debugDescription)
        let downloadButton = safari.webViews.buttons["Download"].firstMatch
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 10), safari.debugDescription)
        activate(downloadButton)
        let loginRequired = safari.webViews.staticTexts["Please log in to download more decks."].firstMatch
        if loginRequired.waitForExistence(timeout: 5) {
            let loginGate = XCTAttachment(string: safari.debugDescription)
            loginGate.name = "Shared Deck Download Requires AnkiWeb Login"
            loginGate.lifetime = .keepAlways
            add(loginGate)
            return
        }

        let downloadConfirmation = safari.descendants(matching: .any).matching(identifier: "SFDialogView").firstMatch
        XCTAssertTrue(downloadConfirmation.waitForExistence(timeout: 10), safari.debugDescription)
        downloadConfirmation.coordinate(withNormalizedOffset: CGVector(dx: 0.89, dy: 0.81)).tap()
        Thread.sleep(forTimeInterval: 5)

        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.activate()
        XCTAssertTrue(files.wait(for: .runningForeground, timeout: 10), files.debugDescription)
        let browse = files.buttons["Explorar"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 10), files.debugDescription)
        activate(browse)
        let downloadsFolder = files.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Downloads", "Transferências")
        ).firstMatch
        XCTAssertTrue(downloadsFolder.waitForExistence(timeout: 15), files.debugDescription)
        activate(downloadsFolder)
        let downloadedPackage = files.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Hiragana_and_Katakana.apkg")
        ).firstMatch
        XCTAssertTrue(downloadedPackage.waitForExistence(timeout: 15), files.debugDescription)
        let filesStateAfterDownload = XCTAttachment(string: files.debugDescription)
        filesStateAfterDownload.name = "Files after Shared Deck Download"
        filesStateAfterDownload.lifetime = .keepAlways
        add(filesStateAfterDownload)
        #endif
    }

    func testMainWindowIsSingleAtLaunch() {
        XCTAssertEqual(app.windows.count, 1, app.debugDescription)
        XCTAssertTrue(app.windows.firstMatch.exists, app.debugDescription)
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let appIcon = springboard.icons.matching(identifier: "AnkiOS").firstMatch
        XCTAssertTrue(appIcon.waitForExistence(timeout: 10), springboard.debugDescription)
        appIcon.press(forDuration: 1.2)
        let newWindow = springboard.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "New Window", "Nova janela")
        ).firstMatch
        XCTAssertTrue(newWindow.waitForExistence(timeout: 10), springboard.debugDescription)
        activate(newWindow)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), app.debugDescription)
        XCTAssertTrue(app.windows.element(boundBy: 1).waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.windows.count, 2, app.debugDescription)
        #endif
    }

    #if os(iOS)
    func testSelectedTabRestoresAfterRelaunch() async throws {
        navigate("Ferramentas")
        XCUIDevice.shared.press(.home)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        app.terminate()
        app.launch()

        let toolsTab = app.tabBars.buttons["Ferramentas"]
        XCTAssertTrue(toolsTab.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(toolsTab.isSelected, app.debugDescription)
    }
    #endif

    #if os(macOS)
    func testMainWindowCanOpenAnotherWindow() {
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.windows.element(boundBy: 1).waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.windows.count, 2, app.debugDescription)
    }
    #endif

    func testICloudSyncIsAbsentFromTools() {
        navigate("Ferramentas")
        XCTAssertFalse(app.buttons["Sincronizar com iCloud"].exists, app.debugDescription)
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "iCloud")).firstMatch.exists,
            app.debugDescription
        )
    }

    func testICloudSyncIsAbsentFromDeckActions() {
        navigate("Baralhos")
        XCTAssertTrue(app.buttons["Sincronizar com AnkiWeb"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["Sincronizar com iCloud"].exists, app.debugDescription)
        XCTAssertFalse(
            app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "iCloud")).firstMatch.exists,
            app.debugDescription
        )
    }

    func testICloudSyncIsAbsentFromProfileTools() {
        navigate("Ferramentas")
        button("Perfis")
        XCTAssertTrue(app.navigationBars["Perfis"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "iCloud")).firstMatch.exists,
            app.debugDescription
        )
    }

    func testDeckCreationAndOptions() {
        createDeck("UI Parent::UI Child")
        activate(app.buttons["deck.options.UI Parent::UI Child"])
        XCTAssertTrue(identified("deck.options.limitMode.new").waitForExistence(timeout: 10), app.debugDescription)
        button("Duplicar preset")
        let presetName = identified("deck.options.preset.name")
        XCTAssertTrue(presetName.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue((presetName.value as? String)?.localizedCaseInsensitiveContains("cópia") == true, app.debugDescription)
        #if os(macOS)
        activate(presetName)
        presetName.typeKey("a", modifierFlags: .command)
        #else
        activate(presetName)
        presetName.press(forDuration: 1)
        let selectAll = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["Selecionar Tudo", "Selecionar tudo", "Select All"])
        ).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), app.debugDescription)
        activate(selectAll)
        #endif
        type("UI Shared", into: presetName)
        XCTAssertEqual(presetName.value as? String, "UI Shared", app.debugDescription)
        button("Salvar")
        XCTAssertTrue(app.buttons["deck.open.UI Parent::UI Child"].waitForExistence(timeout: 10))
        activate(app.buttons["deck.open.UI Parent::UI Child"])
        XCTAssertTrue(app.staticTexts["UI Child"].firstMatch.waitForExistence(timeout: 10))

        createDeck("UI Other")
        activate(app.buttons["deck.options.UI Other"])
        let presetPicker = identified("deck.options.preset")
        XCTAssertTrue(presetPicker.waitForExistence(timeout: 10), app.debugDescription)
        activate(presetPicker)
        let sharedPreset = app.buttons["UI Shared"].firstMatch
        XCTAssertTrue(sharedPreset.waitForExistence(timeout: 10), app.debugDescription)
        activate(sharedPreset)
        XCTAssertEqual(identified("deck.options.preset.name").value as? String, "UI Shared", app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Other"])
        activate(presetPicker)
        let defaultPreset = app.buttons["Default"].firstMatch
        XCTAssertTrue(defaultPreset.waitForExistence(timeout: 10), app.debugDescription)
        activate(defaultPreset)
        button("Apagar preset")
        XCTAssertTrue(app.alerts["Preset padrão"].waitForExistence(timeout: 5), app.debugDescription)
        button("OK")

        activate(presetPicker)
        XCTAssertTrue(sharedPreset.waitForExistence(timeout: 10), app.debugDescription)
        activate(sharedPreset)
        button("Apagar preset")
        XCTAssertEqual(identified("deck.options.preset.name").value as? String, "Default", app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Other"])
        XCTAssertEqual(identified("deck.options.preset.name").value as? String, "Default", app.debugDescription)
        button("Fechar")
        activate(app.buttons["deck.options.UI Parent::UI Child"])
        XCTAssertEqual(identified("deck.options.preset.name").value as? String, "Default", app.debugDescription)
        button("Fechar")
    }

    func testDeckSpecificDailyNewLimitPersists() {
        createDeck("UI Limits")
        activate(app.buttons["deck.options.UI Limits"])

        let limitMode = identified("deck.options.limitMode.new")
        XCTAssertTrue(limitMode.waitForExistence(timeout: 10), app.debugDescription)
        reveal(limitMode)
        activate(limitMode)
        #if os(macOS)
        let deckOption = limitMode.descendants(matching: .menuItem)["Esse baralho"].firstMatch
        XCTAssertTrue(deckOption.waitForExistence(timeout: 10), app.debugDescription)
        activate(deckOption)
        #else
        let deckOption = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["Este baralho", "Esse baralho"])
        ).firstMatch
        XCTAssertTrue(deckOption.waitForExistence(timeout: 10), app.debugDescription)
        activate(deckOption)
        #endif

        let deckLimit = identified("deck.options.limit.new.deck")
        XCTAssertTrue(deckLimit.waitForExistence(timeout: 10), app.debugDescription)
        reveal(deckLimit)
        incrementStepper(deckLimit)
        XCTAssertTrue(String(describing: deckLimit.value ?? "").contains("21"), app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Limits"])
        let savedMode = identified("deck.options.limitMode.new")
        XCTAssertTrue(savedMode.waitForExistence(timeout: 10), app.debugDescription)
        reveal(savedMode)
        let savedModeValue = savedMode.value as? String ?? ""
        XCTAssertTrue(savedMode.label.contains("baralho") || savedModeValue == "deck", app.debugDescription)
        let savedLimit = identified("deck.options.limit.new.deck")
        XCTAssertTrue(savedLimit.waitForExistence(timeout: 10), app.debugDescription)
        reveal(savedLimit)
        XCTAssertTrue(String(describing: savedLimit.value ?? "").contains("21"), app.debugDescription)
    }

    func testDeckReviewLimitForTodayPersists() {
        createDeck("UI Review Today")
        activate(app.buttons["deck.options.UI Review Today"])

        let reviewMode = identified("deck.options.limitMode.review")
        reveal(reviewMode)
        activate(reviewMode)
        menuButton("Somente hoje")

        let todayLimit = identified("deck.options.limit.review.today")
        reveal(todayLimit)
        XCTAssertTrue(todayLimit.waitForExistence(timeout: 10), app.debugDescription)
        incrementStepper(todayLimit)
        XCTAssertTrue(String(describing: todayLimit.value ?? "").contains("201"), app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Review Today"])
        let restoredMode = identified("deck.options.limitMode.review")
        reveal(restoredMode)
        let restoredModeValue = restoredMode.value as? String ?? ""
        XCTAssertTrue(restoredMode.label.contains("Somente hoje") || restoredModeValue == "today", app.debugDescription)
        let restoredLimit = identified("deck.options.limit.review.today")
        reveal(restoredLimit)
        XCTAssertTrue(String(describing: restoredLimit.value ?? "").contains("201"), app.debugDescription)

        let newMode = identified("deck.options.limitMode.new")
        reveal(newMode)
        let newModeValue = newMode.value as? String ?? ""
        XCTAssertTrue(newMode.label.contains("Preset") || newModeValue == "preset", app.debugDescription)
    }

    #if os(iOS)
    func testDeckEasyDaySettingPersistsAfterReopeningOptions() {
        createDeck("UI Easy Day")
        activate(app.buttons["deck.options.UI Easy Day"])

        let saturday = identified("deck.options.picker.Sáb")
        XCTAssertTrue(saturday.waitForExistence(timeout: 10), app.debugDescription)
        reveal(saturday)
        activate(saturday)
        menuButton("Reduzido")
        let selectedValue = "\(saturday.label) \(saturday.value ?? "")"
        XCTAssertTrue(selectedValue.contains("Reduzido") || selectedValue.contains("0.5"), app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Easy Day"])
        let savedSaturday = identified("deck.options.picker.Sáb")
        XCTAssertTrue(savedSaturday.waitForExistence(timeout: 10), app.debugDescription)
        let savedValue = "\(savedSaturday.label) \(savedSaturday.value ?? "")"
        XCTAssertTrue(savedValue.contains("Reduzido") || savedValue.contains("0.5"), app.debugDescription)
    }

    func testDeckLearningStepsPersistAfterReopeningOptions() {
        createDeck("UI Learning Steps")
        activate(app.buttons["deck.options.UI Learning Steps"])

        let steps = app.textFields["1 10"].firstMatch
        XCTAssertTrue(steps.waitForExistence(timeout: 10), app.debugDescription)
        reveal(steps)
        activate(steps)
        let currentSteps = steps.value as? String ?? ""
        XCTAssertEqual(currentSteps, "1 10", app.debugDescription)
        steps.press(forDuration: 1)
        let selectAll = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["Selecionar Tudo", "Selecionar tudo", "Select All"])
        ).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), app.debugDescription)
        activate(selectAll)
        type("1 5 10", into: steps)
        XCTAssertEqual(steps.value as? String, "1 5 10", app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Learning Steps"])
        let savedSteps = app.textFields["1 10"].firstMatch
        XCTAssertTrue(savedSteps.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(savedSteps.value as? String, "1 5 10", app.debugDescription)
    }

    func testDeckNewCardInsertionOrderPersistsAfterReopeningOptions() {
        createDeck("UI New Order")
        activate(app.buttons["deck.options.UI New Order"])

        let insertionOrder = identified("deck.options.picker.Ordem de inserção")
        XCTAssertTrue(insertionOrder.waitForExistence(timeout: 10), app.debugDescription)
        reveal(insertionOrder)
        activate(insertionOrder)
        menuButton("Data de adição")
        let selectedValue = "\(insertionOrder.label) \(insertionOrder.value ?? "")"
        XCTAssertTrue(selectedValue.contains("Data de adição") || selectedValue.contains("1"), app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI New Order"])
        let savedOrder = identified("deck.options.picker.Ordem de inserção")
        XCTAssertTrue(savedOrder.waitForExistence(timeout: 10), app.debugDescription)
        let savedValue = "\(savedOrder.label) \(savedOrder.value ?? "")"
        XCTAssertTrue(savedValue.contains("Data de adição") || savedValue.contains("1"), app.debugDescription)
    }

    func testDeckReviewOrderPersistsAfterReopeningOptions() {
        createDeck("UI Review Order")
        activate(app.buttons["deck.options.UI Review Order"])

        let reviewOrder = identified("deck.options.picker.Ordem das revisões")
        XCTAssertTrue(reviewOrder.waitForExistence(timeout: 10), app.debugDescription)
        reveal(reviewOrder)
        activate(reviewOrder)
        let ascendingInterval = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Intervalos ascendentes")
        ).firstMatch
        XCTAssertTrue(ascendingInterval.waitForExistence(timeout: 10), app.debugDescription)
        activate(ascendingInterval)
        let selectedValue = "\(reviewOrder.label) \(reviewOrder.value ?? "")"
        XCTAssertTrue(selectedValue.contains("Intervalos ascendentes") || selectedValue.contains("3"), app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Review Order"])
        let savedReviewOrder = identified("deck.options.picker.Ordem das revisões")
        XCTAssertTrue(savedReviewOrder.waitForExistence(timeout: 10), app.debugDescription)
        let savedValue = "\(savedReviewOrder.label) \(savedReviewOrder.value ?? "")"
        XCTAssertTrue(savedValue.contains("Intervalos ascendentes") || savedValue.contains("3"), app.debugDescription)
    }

    func testDeckReviewSiblingBurySettingPersistsAfterReopeningOptions() {
        createDeck("UI Review Sibling Bury")
        activate(app.buttons["deck.options.UI Review Sibling Bury"])

        let burySiblings = app.switches.matching(
            NSPredicate(format: "label == %@", "Ocultar irmãos (revisões)")
        ).firstMatch
        XCTAssertTrue(burySiblings.waitForExistence(timeout: 10), app.debugDescription)
        reveal(burySiblings)
        let originalValue = burySiblings.value as? String ?? "0"
        let expectedValue = originalValue == "1" ? "0" : "1"
        activate(burySiblings)
        XCTAssertEqual(burySiblings.value as? String, expectedValue, app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Review Sibling Bury"])
        let savedBurySiblings = app.switches.matching(
            NSPredicate(format: "label == %@", "Ocultar irmãos (revisões)")
        ).firstMatch
        XCTAssertTrue(savedBurySiblings.waitForExistence(timeout: 10), app.debugDescription)
        reveal(savedBurySiblings)
        XCTAssertEqual(savedBurySiblings.value as? String, expectedValue, app.debugDescription)
    }

    func testDeckNewCardsIgnoreReviewLimitPersistsAfterReopeningOptions() {
        createDeck("UI New Ignore Review")
        activate(app.buttons["deck.options.UI New Ignore Review"])

        let ignoreReviewLimit = app.switches.matching(
            NSPredicate(format: "label IN %@", ["Novos cartões ignoram o limite de revisão.", "New cards ignore review limit."])
        ).firstMatch
        XCTAssertTrue(ignoreReviewLimit.waitForExistence(timeout: 10), app.debugDescription)
        reveal(ignoreReviewLimit)
        let originalValue = ignoreReviewLimit.value as? String ?? "0"
        let expectedValue = originalValue == "1" ? "0" : "1"
        activate(ignoreReviewLimit)
        XCTAssertEqual(ignoreReviewLimit.value as? String, expectedValue, app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI New Ignore Review"])
        let savedIgnoreReviewLimit = app.switches.matching(
            NSPredicate(format: "label IN %@", ["Novos cartões ignoram o limite de revisão.", "New cards ignore review limit."])
        ).firstMatch
        XCTAssertTrue(savedIgnoreReviewLimit.waitForExistence(timeout: 10), app.debugDescription)
        reveal(savedIgnoreReviewLimit)
        XCTAssertEqual(savedIgnoreReviewLimit.value as? String, expectedValue, app.debugDescription)
    }

    func testDeckLeechActionPersistsAfterReopeningOptions() {
        createDeck("UI Leech Action")
        activate(app.buttons["deck.options.UI Leech Action"])

        let leechAction = identified("deck.options.picker.Ação de leech")
        XCTAssertTrue(leechAction.waitForExistence(timeout: 10), app.debugDescription)
        reveal(leechAction)
        activate(leechAction)
        menuButton("Apenas marcar tag")
        let selectedValue = leechAction.label + " " + String(describing: leechAction.value ?? "")
        XCTAssertTrue(selectedValue.contains("Apenas marcar tag") || selectedValue.contains("1"), app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Leech Action"])
        let savedLeechAction = identified("deck.options.picker.Ação de leech")
        XCTAssertTrue(savedLeechAction.waitForExistence(timeout: 10), app.debugDescription)
        let savedValue = savedLeechAction.label + " " + String(describing: savedLeechAction.value ?? "")
        XCTAssertTrue(savedValue.contains("Apenas marcar tag") || savedValue.contains("1"), app.debugDescription)
    }

    func testDeckLeechLimitPersistsAfterReopeningOptions() {
        createDeck("UI Leech Limit")
        activate(app.buttons["deck.options.UI Leech Limit"])

        let leechLimit = identified("deck.options.stepper.Limite de leech")
        XCTAssertTrue(leechLimit.waitForExistence(timeout: 10), app.debugDescription)
        reveal(leechLimit)
        let initialValue = Int(leechLimit.value as? String ?? "8") ?? 8
        incrementStepper(leechLimit)
        XCTAssertTrue(String(describing: leechLimit.value ?? "").contains("\(initialValue + 1)"), app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Leech Limit"])
        let savedLeechLimit = identified("deck.options.stepper.Limite de leech")
        XCTAssertTrue(savedLeechLimit.waitForExistence(timeout: 10), app.debugDescription)
        reveal(savedLeechLimit)
        XCTAssertTrue(String(describing: savedLeechLimit.value ?? "").contains("\(initialValue + 1)"), app.debugDescription)
    }

    func testDeckLapseLearningStepsPersistAfterReopeningOptions() {
        createDeck("UI Lapse Steps")
        activate(app.buttons["deck.options.UI Lapse Steps"])

        let steps = app.textFields["10"].firstMatch
        XCTAssertTrue(steps.waitForExistence(timeout: 10), app.debugDescription)
        reveal(steps)
        activate(steps)
        XCTAssertEqual(steps.value as? String, "10", app.debugDescription)
        steps.press(forDuration: 1)
        let selectAll = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["Selecionar Tudo", "Selecionar tudo", "Select All"])
        ).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), app.debugDescription)
        activate(selectAll)
        type("10 20", into: steps)
        XCTAssertEqual(steps.value as? String, "10 20", app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Lapse Steps"])
        let savedSteps = app.textFields["10"].firstMatch
        XCTAssertTrue(savedSteps.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(savedSteps.value as? String, "10 20", app.debugDescription)
    }

    func testDeckLapseMinimumIntervalPersistsAfterReopeningOptions() {
        createDeck("UI Lapse Minimum")
        activate(app.buttons["deck.options.UI Lapse Minimum"])

        let minimumInterval = identified("deck.options.stepper.Intervalo mínimo (d)")
        XCTAssertTrue(minimumInterval.waitForExistence(timeout: 10), app.debugDescription)
        reveal(minimumInterval)
        let initialValue = Int(minimumInterval.value as? String ?? "1") ?? 1
        incrementStepper(minimumInterval)
        XCTAssertTrue(String(describing: minimumInterval.value ?? "").contains("\(initialValue + 1)"), app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Lapse Minimum"])
        let savedMinimumInterval = identified("deck.options.stepper.Intervalo mínimo (d)")
        XCTAssertTrue(savedMinimumInterval.waitForExistence(timeout: 10), app.debugDescription)
        reveal(savedMinimumInterval)
        XCTAssertTrue(String(describing: savedMinimumInterval.value ?? "").contains("\(initialValue + 1)"), app.debugDescription)
    }

    func testDeckLapseMultiplierPersistsAfterReopeningOptions() {
        createDeck("UI Lapse Multiplier")
        activate(app.buttons["deck.options.UI Lapse Multiplier"])

        let multiplier = identified("deck.options.stepper.Multiplicador de lapso (%)")
        XCTAssertTrue(multiplier.waitForExistence(timeout: 10), app.debugDescription)
        reveal(multiplier)
        let initialValue = String(describing: multiplier.value ?? "")
        incrementStepper(multiplier)
        let changedValue = String(describing: multiplier.value ?? "")
        XCTAssertNotEqual(changedValue, initialValue, app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Lapse Multiplier"])
        let savedMultiplier = identified("deck.options.stepper.Multiplicador de lapso (%)")
        XCTAssertTrue(savedMultiplier.waitForExistence(timeout: 10), app.debugDescription)
        reveal(savedMultiplier)
        XCTAssertEqual(String(describing: savedMultiplier.value ?? ""), changedValue, app.debugDescription)
    }

    func testDeckReviewMaximumIntervalPersistsAfterReopeningOptions() {
        createDeck("UI Review Maximum Interval")
        activate(app.buttons["deck.options.UI Review Maximum Interval"])

        let maximumInterval = identified("deck.options.stepper.Intervalo máx. (d)")
        XCTAssertTrue(maximumInterval.waitForExistence(timeout: 10), app.debugDescription)
        reveal(maximumInterval)
        let initialValue = String(describing: maximumInterval.value ?? "")
        incrementStepper(maximumInterval)
        let changedValue = String(describing: maximumInterval.value ?? "")
        XCTAssertNotEqual(changedValue, initialValue, app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Review Maximum Interval"])
        let savedMaximumInterval = identified("deck.options.stepper.Intervalo máx. (d)")
        XCTAssertTrue(savedMaximumInterval.waitForExistence(timeout: 10), app.debugDescription)
        reveal(savedMaximumInterval)
        XCTAssertEqual(String(describing: savedMaximumInterval.value ?? ""), changedValue, app.debugDescription)
    }

    func testDeckMaximumAnswerTimePersistsAfterReopeningOptions() {
        createDeck("UI Maximum Answer Time")
        activate(app.buttons["deck.options.UI Maximum Answer Time"])

        let maximumAnswerTime = identified("deck.options.stepper.Tempo máx. por resposta (s)")
        XCTAssertTrue(maximumAnswerTime.waitForExistence(timeout: 10), app.debugDescription)
        reveal(maximumAnswerTime)
        let initialValue = String(describing: maximumAnswerTime.value ?? "")
        incrementStepper(maximumAnswerTime)
        let changedValue = String(describing: maximumAnswerTime.value ?? "")
        XCTAssertNotEqual(changedValue, initialValue, app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Maximum Answer Time"])
        let savedMaximumAnswerTime = identified("deck.options.stepper.Tempo máx. por resposta (s)")
        XCTAssertTrue(savedMaximumAnswerTime.waitForExistence(timeout: 10), app.debugDescription)
        reveal(savedMaximumAnswerTime)
        XCTAssertEqual(String(describing: savedMaximumAnswerTime.value ?? ""), changedValue, app.debugDescription)
    }

    func testDeckNewCardSortOrderPersistsAfterReopeningOptions() {
        createDeck("UI New Card Sort")
        activate(app.buttons["deck.options.UI New Card Sort"])

        let sortOrder = identified("deck.options.picker.Ordenação dos novos")
        XCTAssertTrue(sortOrder.waitForExistence(timeout: 10), app.debugDescription)
        reveal(sortOrder)
        activate(sortOrder)
        menuButton("Cartões aleatórios")
        let selectedValue = "\(sortOrder.label) \(sortOrder.value ?? "")"
        XCTAssertTrue(selectedValue.localizedCaseInsensitiveContains("Cartões aleatórios"), app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI New Card Sort"])
        let savedSortOrder = identified("deck.options.picker.Ordenação dos novos")
        XCTAssertTrue(savedSortOrder.waitForExistence(timeout: 10), app.debugDescription)
        let savedValue = "\(savedSortOrder.label) \(savedSortOrder.value ?? "")"
        XCTAssertTrue(savedValue.localizedCaseInsensitiveContains("Cartões aleatórios"), app.debugDescription)
    }

    func testDeckNewAndReviewMixOrderPersistsAfterReopeningOptions() {
        createDeck("UI New Review Mix")
        activate(app.buttons["deck.options.UI New Review Mix"])

        let mixOrder = identified("deck.options.picker.Novos vs revisões")
        XCTAssertTrue(mixOrder.waitForExistence(timeout: 10), app.debugDescription)
        reveal(mixOrder)
        activate(mixOrder)
        menuButton("Antes das revisões")
        let selectedValue = "\(mixOrder.label) \(mixOrder.value ?? "")"
        XCTAssertTrue(selectedValue.localizedCaseInsensitiveContains("Antes das revisões"), app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI New Review Mix"])
        let savedMixOrder = identified("deck.options.picker.Novos vs revisões")
        XCTAssertTrue(savedMixOrder.waitForExistence(timeout: 10), app.debugDescription)
        let savedValue = "\(savedMixOrder.label) \(savedMixOrder.value ?? "")"
        XCTAssertTrue(savedValue.localizedCaseInsensitiveContains("Antes das revisões"), app.debugDescription)
    }

    func testDeckNewCardGatherPriorityPersistsAfterReopeningOptions() {
        createDeck("UI New Gather Priority")
        activate(app.buttons["deck.options.UI New Gather Priority"])

        let gatherPriority = identified("deck.options.picker.Prioridade ao reunir novos")
        XCTAssertTrue(gatherPriority.waitForExistence(timeout: 10), app.debugDescription)
        reveal(gatherPriority)
        activate(gatherPriority)
        menuButton("Posição ascendente")
        let selectedValue = "\(gatherPriority.label) \(gatherPriority.value ?? "")"
        XCTAssertTrue(selectedValue.localizedCaseInsensitiveContains("Posição ascendente"), app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI New Gather Priority"])
        let savedGatherPriority = identified("deck.options.picker.Prioridade ao reunir novos")
        XCTAssertTrue(savedGatherPriority.waitForExistence(timeout: 10), app.debugDescription)
        let savedValue = "\(savedGatherPriority.label) \(savedGatherPriority.value ?? "")"
        XCTAssertTrue(savedValue.localizedCaseInsensitiveContains("Posição ascendente"), app.debugDescription)
    }

    func testDeckInterdayLearningAndReviewMixOrderPersistsAfterReopeningOptions() {
        createDeck("UI Interday Review Mix")
        activate(app.buttons["deck.options.UI Interday Review Mix"])

        let mixOrder = identified("deck.options.picker.Aprend. interdiária vs revisões")
        XCTAssertTrue(mixOrder.waitForExistence(timeout: 10), app.debugDescription)
        reveal(mixOrder)
        activate(mixOrder)
        menuButton("Antes das revisões")
        let selectedValue = "\(mixOrder.label) \(mixOrder.value ?? "")"
        XCTAssertTrue(selectedValue.localizedCaseInsensitiveContains("Antes das revisões"), app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Interday Review Mix"])
        let savedMixOrder = identified("deck.options.picker.Aprend. interdiária vs revisões")
        XCTAssertTrue(savedMixOrder.waitForExistence(timeout: 10), app.debugDescription)
        let savedValue = "\(savedMixOrder.label) \(savedMixOrder.value ?? "")"
        XCTAssertTrue(savedValue.localizedCaseInsensitiveContains("Antes das revisões"), app.debugDescription)
    }

    func testDeckNewSiblingBurySettingPersistsAfterReopeningOptions() {
        createDeck("UI New Sibling Bury")
        activate(app.buttons["deck.options.UI New Sibling Bury"])

        let buryNewSiblings = app.switches.matching(
            NSPredicate(format: "label == %@", "Ocultar irmãos (novos)")
        ).firstMatch
        XCTAssertTrue(buryNewSiblings.waitForExistence(timeout: 10), app.debugDescription)
        reveal(buryNewSiblings)
        let originalValue = buryNewSiblings.value as? String ?? "0"
        let expectedValue = originalValue == "1" ? "0" : "1"
        activate(buryNewSiblings)
        XCTAssertEqual(buryNewSiblings.value as? String, expectedValue, app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI New Sibling Bury"])
        let savedBuryNewSiblings = app.switches.matching(
            NSPredicate(format: "label == %@", "Ocultar irmãos (novos)")
        ).firstMatch
        XCTAssertTrue(savedBuryNewSiblings.waitForExistence(timeout: 10), app.debugDescription)
        reveal(savedBuryNewSiblings)
        XCTAssertEqual(savedBuryNewSiblings.value as? String, expectedValue, app.debugDescription)
    }

    func testDeckGraduatingIntervalPersistsAfterReopeningOptions() {
        createDeck("UI Graduating Interval")
        activate(app.buttons["deck.options.UI Graduating Interval"])

        let graduatingInterval = identified("deck.options.stepper.Intervalo de graduação (d)")
        XCTAssertTrue(graduatingInterval.waitForExistence(timeout: 10), app.debugDescription)
        reveal(graduatingInterval)
        let initialValue = String(describing: graduatingInterval.value ?? "")
        incrementStepper(graduatingInterval)
        let changedValue = String(describing: graduatingInterval.value ?? "")
        XCTAssertNotEqual(changedValue, initialValue, app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Graduating Interval"])
        let savedGraduatingInterval = identified("deck.options.stepper.Intervalo de graduação (d)")
        XCTAssertTrue(savedGraduatingInterval.waitForExistence(timeout: 10), app.debugDescription)
        reveal(savedGraduatingInterval)
        XCTAssertEqual(String(describing: savedGraduatingInterval.value ?? ""), changedValue, app.debugDescription)
    }

    func testDeckEasyIntervalPersistsAfterReopeningOptions() {
        createDeck("UI Easy Interval")
        activate(app.buttons["deck.options.UI Easy Interval"])

        let easyInterval = identified("deck.options.stepper.Intervalo fácil (d)")
        XCTAssertTrue(easyInterval.waitForExistence(timeout: 10), app.debugDescription)
        reveal(easyInterval)
        let initialValue = String(describing: easyInterval.value ?? "")
        incrementStepper(easyInterval)
        let changedValue = String(describing: easyInterval.value ?? "")
        XCTAssertNotEqual(changedValue, initialValue, app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Easy Interval"])
        let savedEasyInterval = identified("deck.options.stepper.Intervalo fácil (d)")
        XCTAssertTrue(savedEasyInterval.waitForExistence(timeout: 10), app.debugDescription)
        reveal(savedEasyInterval)
        XCTAssertEqual(String(describing: savedEasyInterval.value ?? ""), changedValue, app.debugDescription)
    }

    func testDeckInitialFactorPersistsAfterReopeningOptions() {
        createDeck("UI Initial Factor")
        activate(app.buttons["deck.options.UI Initial Factor"])

        let initialFactor = identified("deck.options.stepper.Fator inicial (%)")
        XCTAssertTrue(initialFactor.waitForExistence(timeout: 10), app.debugDescription)
        reveal(initialFactor)
        let initialValue = String(describing: initialFactor.value ?? "")
        incrementStepper(initialFactor)
        let changedValue = String(describing: initialFactor.value ?? "")
        XCTAssertNotEqual(changedValue, initialValue, app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Initial Factor"])
        let savedInitialFactor = identified("deck.options.stepper.Fator inicial (%)")
        XCTAssertTrue(savedInitialFactor.waitForExistence(timeout: 10), app.debugDescription)
        reveal(savedInitialFactor)
        XCTAssertEqual(String(describing: savedInitialFactor.value ?? ""), changedValue, app.debugDescription)
    }

    func testDeckReviewIntervalModifierPersistsAfterReopeningOptions() {
        createDeck("UI Review Interval Modifier")
        activate(app.buttons["deck.options.UI Review Interval Modifier"])

        let intervalModifier = identified("deck.options.stepper.Modificador de intervalo (%)")
        XCTAssertTrue(intervalModifier.waitForExistence(timeout: 10), app.debugDescription)
        reveal(intervalModifier)
        let initialValue = String(describing: intervalModifier.value ?? "")
        incrementStepper(intervalModifier)
        let changedValue = String(describing: intervalModifier.value ?? "")
        XCTAssertNotEqual(changedValue, initialValue, app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Review Interval Modifier"])
        let savedIntervalModifier = identified("deck.options.stepper.Modificador de intervalo (%)")
        XCTAssertTrue(savedIntervalModifier.waitForExistence(timeout: 10), app.debugDescription)
        reveal(savedIntervalModifier)
        XCTAssertEqual(String(describing: savedIntervalModifier.value ?? ""), changedValue, app.debugDescription)
    }

    func testDeckHardFactorPersistsAfterReopeningOptions() {
        createDeck("UI Hard Factor")
        activate(app.buttons["deck.options.UI Hard Factor"])

        let hardFactor = identified("deck.options.stepper.Fator de difícil (%)")
        XCTAssertTrue(hardFactor.waitForExistence(timeout: 10), app.debugDescription)
        reveal(hardFactor)
        let initialValue = String(describing: hardFactor.value ?? "")
        let decrement = hardFactor.buttons.element(boundBy: 0)
        XCTAssertTrue(decrement.exists, app.debugDescription)
        activate(decrement)
        let changedValue = String(describing: hardFactor.value ?? "")
        XCTAssertNotEqual(changedValue, initialValue, app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Hard Factor"])
        let savedHardFactor = identified("deck.options.stepper.Fator de difícil (%)")
        XCTAssertTrue(savedHardFactor.waitForExistence(timeout: 10), app.debugDescription)
        reveal(savedHardFactor)
        XCTAssertEqual(String(describing: savedHardFactor.value ?? ""), changedValue, app.debugDescription)
    }

    func testDeckEasyMultiplierPersistsAfterReopeningOptions() {
        createDeck("UI Easy Multiplier")
        activate(app.buttons["deck.options.UI Easy Multiplier"])

        let easyMultiplier = identified("deck.options.stepper.Multiplicador de fácil (%)")
        XCTAssertTrue(easyMultiplier.waitForExistence(timeout: 10), app.debugDescription)
        reveal(easyMultiplier)
        let initialValue = String(describing: easyMultiplier.value ?? "")
        incrementStepper(easyMultiplier)
        let changedValue = String(describing: easyMultiplier.value ?? "")
        XCTAssertNotEqual(changedValue, initialValue, app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI Easy Multiplier"])
        let savedEasyMultiplier = identified("deck.options.stepper.Multiplicador de fácil (%)")
        XCTAssertTrue(savedEasyMultiplier.waitForExistence(timeout: 10), app.debugDescription)
        reveal(savedEasyMultiplier)
        XCTAssertEqual(String(describing: savedEasyMultiplier.value ?? ""), changedValue, app.debugDescription)
    }

    func testDeckFSRSRescheduleSettingPersistsAfterReopeningOptions() {
        createDeck("UI FSRS Reschedule")
        navigate("Ferramentas")
        button("Preferências do AnkiOS")

        let fsrs = identified("settings.scheduler.fsrs")
        XCTAssertTrue(fsrs.waitForExistence(timeout: 10), app.debugDescription)
        if (fsrs.value as? String) != "1" { activate(fsrs) }

        app.terminate()
        app.launch()
        navigate("Baralhos")
        activate(app.buttons["deck.options.UI FSRS Reschedule"])

        let reschedule = app.switches.matching(
            NSPredicate(format: "label IN %@", ["Reagendar cartões ao alterar", "Reschedule cards on change"])
        ).firstMatch
        XCTAssertTrue(reschedule.waitForExistence(timeout: 10), app.debugDescription)
        reveal(reschedule)
        XCTAssertEqual(reschedule.value as? String, "0", app.debugDescription)
        activate(reschedule)
        XCTAssertEqual(reschedule.value as? String, "1", app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI FSRS Reschedule"])
        let savedReschedule = app.switches.matching(
            NSPredicate(format: "label IN %@", ["Reagendar cartões ao alterar", "Reschedule cards on change"])
        ).firstMatch
        XCTAssertTrue(savedReschedule.waitForExistence(timeout: 10), app.debugDescription)
        reveal(savedReschedule)
        XCTAssertEqual(savedReschedule.value as? String, "0", app.debugDescription)
    }

    func testFSRSHealthCheckSettingPersistsAfterReopeningOptions() {
        navigate("Ferramentas")
        button("Preferências do AnkiOS")

        let fsrs = identified("settings.scheduler.fsrs")
        XCTAssertTrue(fsrs.waitForExistence(timeout: 10), app.debugDescription)
        if (fsrs.value as? String) != "1" { activate(fsrs) }

        app.terminate()
        app.launch()
        navigate("Baralhos")
        activate(app.buttons["deck.options.Default"])

        let healthCheck = app.switches.matching(
            NSPredicate(format: "label IN %@", ["Verificar qualidade ao otimizar (lento)", "Check FSRS health (slow)"])
        ).firstMatch
        XCTAssertTrue(healthCheck.waitForExistence(timeout: 10), app.debugDescription)
        reveal(healthCheck)
        let originalValue = healthCheck.value as? String ?? "1"
        let expectedValue = originalValue == "1" ? "0" : "1"
        activate(healthCheck)
        XCTAssertEqual(healthCheck.value as? String, expectedValue, app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.Default"])
        let savedHealthCheck = app.switches.matching(
            NSPredicate(format: "label IN %@", ["Verificar qualidade ao otimizar (lento)", "Check FSRS health (slow)"])
        ).firstMatch
        XCTAssertTrue(savedHealthCheck.waitForExistence(timeout: 10), app.debugDescription)
        reveal(savedHealthCheck)
        XCTAssertEqual(savedHealthCheck.value as? String, expectedValue, app.debugDescription)
    }

    #if os(iOS)
    func testFSRSOptimizerComputesAndPersistsParametersFromReviewHistory() {
        finishTutorialIfPresented()
        navigate("Ferramentas")
        button("Importar .apkg, .colpkg ou Mnemosyne .db")

        let fixture = app.cells.matching(
            NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", "ankios-fsrs-optimizer", "ankios-fsrs-optimizer")
        ).firstMatch
        if !fixture.waitForExistence(timeout: 8) {
            let browse = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Explorar")
            ).firstMatch
            if browse.exists { activate(browse) }
            let downloads = app.cells.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Downloads")
            ).firstMatch
            XCTAssertTrue(downloads.waitForExistence(timeout: 10), app.debugDescription)
            activate(downloads)
        }
        XCTAssertTrue(fixture.waitForExistence(timeout: 15), app.debugDescription)
        activate(fixture)
        XCTAssertTrue(app.navigationBars["Importar pacote"].waitForExistence(timeout: 10), app.debugDescription)

        let scheduling = identified("packageImport.scheduling")
        XCTAssertTrue(scheduling.waitForExistence(timeout: 10), app.debugDescription)
        activate(scheduling)
        XCTAssertEqual(scheduling.value as? String, "1", app.debugDescription)
        button("Importar")
        let importMessage = app.alerts.firstMatch
        if importMessage.waitForExistence(timeout: 10) { button("OK") }
        finishTutorialIfPresented()

        navigate("Baralhos")
        XCTAssertTrue(app.buttons["deck.open.UI FSRS Optimizer"].waitForExistence(timeout: 30), app.debugDescription)
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let fsrs = identified("settings.scheduler.fsrs")
        XCTAssertTrue(fsrs.waitForExistence(timeout: 10), app.debugDescription)
        if (fsrs.value as? String) != "1" { activate(fsrs) }

        navigate("Baralhos")
        activate(app.buttons["deck.options.UI FSRS Optimizer"])
        let optimizer = identified("deck.options.fsrs.optimize")
        XCTAssertTrue(optimizer.waitForExistence(timeout: 10), app.debugDescription)
        reveal(optimizer)
        activate(optimizer)

        let status = identified("deck.options.fsrs.optimizationStatus")
        let optimizedDeck = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Parâmetros calculados para 4 cartões"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [optimizedDeck], timeout: 180), .completed, app.debugDescription)

        let optimizeAll = identified("deck.options.fsrs.optimizeAll")
        reveal(optimizeAll)
        activate(optimizeAll)
        let optimizedPresets = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Parâmetros calculados para 1 presets"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [optimizedPresets], timeout: 180), .completed, app.debugDescription)
        button("Salvar")

        activate(app.buttons["deck.options.UI FSRS Optimizer"])
        let weights = identified("deck.options.fsrs.weights")
        XCTAssertTrue(weights.waitForExistence(timeout: 10), app.debugDescription)
        reveal(weights)
        let savedWeights = (weights.value as? String ?? "").split(whereSeparator: { $0.isWhitespace })
        XCTAssertEqual(savedWeights.count, 21, app.debugDescription)
    }

    func testFSRSOptimizerReportsInsufficientHistory() {
        navigate("Ferramentas")
        button("Preferências do AnkiOS")

        let fsrs = identified("settings.scheduler.fsrs")
        XCTAssertTrue(fsrs.waitForExistence(timeout: 10), app.debugDescription)
        let wasEnabled = (fsrs.value as? String) == "1"
        if !wasEnabled { activate(fsrs) }

        navigate("Baralhos")
        activate(app.buttons["deck.options.Default"])

        let optimizer = identified("deck.options.fsrs.optimize")
        XCTAssertTrue(optimizer.waitForExistence(timeout: 10), app.debugDescription)
        reveal(optimizer)
        activate(optimizer)

        let status = identified("deck.options.fsrs.optimizationStatus")
        let insufficientHistory = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "pelo menos oito revisões"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [insufficientHistory], timeout: 15), .completed, app.debugDescription)

        let optimizeAll = identified("deck.options.fsrs.optimizeAll")
        reveal(optimizeAll)
        activate(optimizeAll)
        let allPresetsInsufficientHistory = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "pelo menos oito revisões"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [allPresetsInsufficientHistory], timeout: 10), .completed, app.debugDescription)
        button("Fechar")
    }
    #endif
    #endif

    func testDeckHierarchyRenameMoveAndDelete() {
        createDeck("UI Parent")
        createDeck("UI Parent::UI Child")

        openDeckContextMenu("UI Parent")
        menuButton("Renomear")
        #if os(macOS)
        let name = app.windows.firstMatch.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Nome")).firstMatch
        #else
        let name = app.alerts.textFields["Nome"].firstMatch
        #endif
        XCTAssertTrue(name.waitForExistence(timeout: 10), app.debugDescription)
        let previousName = name.value as? String ?? ""
        activate(name)
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previousName.count))
        name.typeText("UI Renamed")
        button("Renomear")
        XCTAssertTrue(app.buttons["deck.open.UI Renamed"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["deck.open.UI Renamed::UI Child"].waitForExistence(timeout: 10), app.debugDescription)

        openDeckContextMenu("UI Renamed::UI Child")
        menuButton("Mover para")
        menuButton("Raiz")
        XCTAssertTrue(app.buttons["deck.open.UI Child"].waitForExistence(timeout: 10), app.debugDescription)

        openDeckContextMenu("UI Renamed")
        menuButton("Apagar")
        button("Apagar baralho")
        XCTAssertFalse(app.buttons["deck.open.UI Renamed"].waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertTrue(app.buttons["deck.open.UI Child"].exists, app.debugDescription)
    }

    func testDeckCollapseAndExpandAll() {
        createDeck("UI Collapse Parent")
        createDeck("UI Collapse Parent::UI Collapse Child")

        button("Mais ações dos baralhos")
        button("Recolher todos")
        XCTAssertFalse(app.buttons["deck.open.UI Collapse Parent::UI Collapse Child"].exists, app.debugDescription)

        button("Mais ações dos baralhos")
        button("Expandir todos")
        XCTAssertTrue(app.buttons["deck.open.UI Collapse Parent::UI Collapse Child"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testDeckDueCountsRefreshAfterStudy() {
        addNote(front: "UI Due Count \(UUID().uuidString)", back: "UI Due Count answer")
        navigate("Baralhos")

        #if os(macOS)
        XCTAssertEqual(deckCounts("Default"), ["1", "0", "0"])
        #else
        let newCount = identified("deck.count.Default.new")
        XCTAssertTrue(newCount.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(newCount.label, "1", app.debugDescription)
        #endif

        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        button("Mostrar resposta")
        activate(identified("study.rating.3"))
        button("study.close")
        button("deck.overview.close")

        #if os(macOS)
        XCTAssertEqual(deckCounts("Default"), ["0", "1", "0"])
        #else
        let learningCount = identified("deck.count.Default.learn")
        XCTAssertTrue(learningCount.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(learningCount.label, "1", app.debugDescription)
        XCTAssertEqual(identified("deck.count.Default.new").label, "0", app.debugDescription)
        #endif
    }

    func testAddSearchAndDuplicateWarning() {
        #if os(iOS)
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        for identifier in [
            "preferences.Sincronizar áudio e imagens",
            "preferences.Sincronizar ao abrir e fechar o perfil",
            "preferences.Sincronizar mídia a cada 15 minutos"
        ] {
            let setting = identified(identifier)
            reveal(setting)
            if (setting.value as? String) != "0" { activate(setting) }
        }
        button("Salvar preferências")
        #endif

        navigate("Adicionar")
        addNote(tags: "ui-parity")
        enter("UI question", into: app.textViews["field.source.Front"].firstMatch)
        button("add.submit")
        #if os(macOS)
        let cancelDuplicate = app.windows.firstMatch.descendants(matching: .button).matching(identifier: "action-button-2").firstMatch
        XCTAssertTrue(cancelDuplicate.waitForExistence(timeout: 10), app.debugDescription)
        cancelDuplicate.click()
        #else
        XCTAssertTrue(app.alerts["Nota possivelmente duplicada"].waitForExistence(timeout: 10))
        button("Cancelar")
        let submit = identified("add.submit")
        XCTAssertTrue(submit.exists, app.debugDescription)
        activate(submit)
        let warning = app.alerts["Nota possivelmente duplicada"]
        XCTAssertTrue(warning.waitForExistence(timeout: 10), app.debugDescription)
        let addAnyway = warning.buttons["Adicionar mesmo assim"]
        XCTAssertTrue(addAnyway.exists, app.debugDescription)
        activate(addAnyway)
        XCTAssertTrue(app.staticTexts["Nota adicionada."].waitForExistence(timeout: 10), app.debugDescription)
        #endif
        navigate("Painel")
        search("UI question")
        #if os(macOS)
        XCTAssertTrue(app.outlines.staticTexts["UI question"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        #else
        let duplicateResults = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "UI question")
        )
        XCTAssertTrue(duplicateResults.element(boundBy: 1).waitForExistence(timeout: 10), app.debugDescription)
        #endif
        search("tag:ui-parity")
        let taggedResults = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "UI question")
        )
        XCTAssertTrue(taggedResults.element(boundBy: 1).waitForExistence(timeout: 10), app.debugDescription)

        #if os(iOS)
        let urlFront = "UI callback \(UUID().uuidString.prefix(8))"
        var addComponents = URLComponents(string: "anki://x-callback-url/addnote")!
        addComponents.queryItems = [
            URLQueryItem(name: "type", value: "Basic"),
            URLQueryItem(name: "deck", value: "Default"),
            URLQueryItem(name: "fldFront", value: urlFront),
            URLQueryItem(name: "fldBack", value: "Added from URL"),
            URLQueryItem(name: "tags", value: "url-parity"),
            URLQueryItem(name: "x-success", value: "https://example.invalid/anki-add-callback")
        ]
        openAnkiURL(addComponents.url!)
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), safari.debugDescription)
        app.activate()
        navigate("Painel")
        search(urlFront)
        let urlResults = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", urlFront))
        XCTAssertTrue(urlResults.firstMatch.waitForExistence(timeout: 10), app.debugDescription)

        addComponents.queryItems?.removeAll { $0.name == "x-success" }
        openAnkiURL(addComponents.url!)
        let duplicateError = app.alerts["Erro"]
        XCTAssertTrue(duplicateError.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(duplicateError.staticTexts["Uma anotação com o mesmo primeiro campo já existe."].exists, app.debugDescription)
        XCTAssertFalse(safari.wait(for: .runningForeground, timeout: 2), safari.debugDescription)
        activate(duplicateError.buttons["OK"])

        addComponents.queryItems?.append(URLQueryItem(name: "dupes", value: "1"))
        addComponents.queryItems?.append(URLQueryItem(name: "x-success", value: "https://example.invalid/anki-duplicate-callback"))
        openAnkiURL(addComponents.url!)
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), safari.debugDescription)
        app.activate()
        navigate("Painel")
        search(urlFront)
        XCTAssertTrue(urlResults.element(boundBy: 1).waitForExistence(timeout: 10), app.debugDescription)

        #endif
    }

    func testImageOcclusionEditorControlsAndValidation() {
        navigate("Adicionar")
        activate(identified("add.imageOcclusion"))

        let shape = identified("imageOcclusion.shape")
        XCTAssertTrue(shape.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(shape.buttons["Retângulo"].isSelected, app.debugDescription)
        activate(shape.buttons["Elipse"])
        XCTAssertTrue(shape.buttons["Elipse"].isSelected, app.debugDescription)

        let hideOthers = app.switches["imageOcclusion.hideOthers"]
        XCTAssertTrue(hideOthers.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(hideOthers.value as? String, "1", app.debugDescription)
        let hideOthersControl = hideOthers.descendants(matching: .switch).firstMatch
        XCTAssertTrue(hideOthersControl.exists, app.debugDescription)
        activate(hideOthersControl)
        XCTAssertTrue(app.staticTexts["Cada cartão esconde só a própria máscara."].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(hideOthers.value as? String, "0", app.debugDescription)

        activate(identified("imageOcclusion.save"))
        let alert = app.alerts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Oclusão de imagem")
        ).firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(alert.staticTexts["Escolha uma imagem."].exists, app.debugDescription)
        activate(alert.buttons["OK"])
        activate(identified("imageOcclusion.close"))
    }

    #if os(iOS)
    func testImageOcclusionDrawsAndPersistsMasks() {
        finishTutorialIfPresented()
        navigate("Adicionar")
        let openOcclusion = identified("add.imageOcclusion")
        XCTAssertTrue(openOcclusion.waitForExistence(timeout: 10), app.debugDescription)
        activate(openOcclusion)
        activate(identified("imageOcclusion.chooseImage"))

        let fixture = app.cells.matching(
            NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", "ankios-picker-fixture", "ankios-picker-fixture")
        ).firstMatch
        if !fixture.waitForExistence(timeout: 8) {
            let browse = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Explorar")
            ).firstMatch
            if browse.exists { activate(browse) }
            let downloads = app.cells.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Downloads")
            ).firstMatch
            XCTAssertTrue(downloads.waitForExistence(timeout: 10), app.debugDescription)
            activate(downloads)
        }
        XCTAssertTrue(fixture.waitForExistence(timeout: 15), app.debugDescription)
        activate(fixture)

        let canvas = identified("imageOcclusion.canvas")
        XCTAssertTrue(canvas.waitForExistence(timeout: 10), app.debugDescription)
        let firstStart = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.22))
        let firstEnd = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.46, dy: 0.46))
        firstStart.press(forDuration: 0.1, thenDragTo: firstEnd)
        XCTAssertTrue(app.staticTexts["Máscara 1"].waitForExistence(timeout: 5), app.debugDescription)

        let shape = identified("imageOcclusion.shape")
        activate(shape.buttons["Elipse"])
        let secondStart = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.54, dy: 0.54))
        let secondEnd = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.78))
        secondStart.press(forDuration: 0.1, thenDragTo: secondEnd)
        XCTAssertTrue(app.staticTexts["Máscara 2"].waitForExistence(timeout: 5), app.debugDescription)

        let hideOthers = app.switches["imageOcclusion.hideOthers"]
        XCTAssertTrue(hideOthers.waitForExistence(timeout: 5), app.debugDescription)
        let hideOthersControl = hideOthers.descendants(matching: .switch).firstMatch
        activate(hideOthersControl)
        XCTAssertEqual(hideOthers.value as? String, "0", app.debugDescription)

        activate(identified("imageOcclusion.save"))

        navigate("Baralhos")
        navigate("Adicionar")
        let historyItem = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "add.history.")
        ).firstMatch
        XCTAssertTrue(historyItem.waitForExistence(timeout: 10), app.debugDescription)
        activate(historyItem)

        let editMasks = identified("imageOcclusion.editMasks")
        reveal(editMasks)
        activate(editMasks)
        XCTAssertTrue(app.staticTexts["Máscara 1"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Máscara 2"].exists, app.debugDescription)
        let reopenedHideOthers = app.switches["imageOcclusion.hideOthers"]
        XCTAssertTrue(reopenedHideOthers.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(reopenedHideOthers.value as? String, "0", app.debugDescription)
    }
    #endif

    func testStudyAnswerAndUndo() {
        addNote()
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        activate(identified("study.revealAnswer"))
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "Resposta"
        tree.lifetime = .keepAlways
        add(tree)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        activate(identified("study.rating.3"))
        activate(identified("study.moreMenu"))
        menuButton("Desfazer", swipeDown: true)
        XCTAssertTrue(identified("study.revealAnswer").waitForExistence(timeout: 10), app.debugDescription)
        #if os(macOS)
        XCTAssertFalse(identified("study.rating.3").exists, app.debugDescription)
        #else
        activate(identified("study.revealAnswer"))
        XCTAssertTrue(app.webViews.staticTexts["UI answer"].firstMatch.waitForExistence(timeout: 10))
        #endif
    }

    #if os(iOS)
    func testStudyToolsCopyForgetAndDeleteNote() {
        addNote(front: "UI Study copy source", back: "UI Study copy response")
        addNote(front: "UI Study delete target", back: "UI Study delete response")
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")

        let copyFront = "UI Study copy source"
        let deleteFront = "UI Study delete target"
        let copyCard = app.webViews.staticTexts[copyFront]
        let deleteCard = app.webViews.staticTexts[deleteFront]
        let currentFront: String
        if copyCard.waitForExistence(timeout: 10) {
            currentFront = copyFront
        } else {
            XCTAssertTrue(deleteCard.waitForExistence(timeout: 10), app.debugDescription)
            currentFront = deleteFront
        }
        let nextFront = currentFront == copyFront ? deleteFront : copyFront
        let toolsButton = identified("study.topBar.action")

        activate(toolsButton)
        activate(revealStudyToolAction("createCopy"))
        XCTAssertTrue(app.navigationBars["Criar cópia"].waitForExistence(timeout: 10), app.debugDescription)
        let copiedFront = app.textViews.matching(NSPredicate(format: "value == %@", currentFront)).firstMatch
        XCTAssertTrue(copiedFront.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(copiedFront.value as? String, currentFront, app.debugDescription)
        activate(identified("noteEditor.close"))
        XCTAssertTrue(app.webViews.staticTexts[currentFront].waitForExistence(timeout: 10), app.debugDescription)

        activate(toolsButton)
        activate(revealStudyToolAction("forgetCard"))
        XCTAssertTrue(app.webViews.staticTexts[nextFront].waitForExistence(timeout: 10), app.debugDescription)

        activate(revealStudyToolAction("deleteNote"))
        let deleteConfirmation = app.sheets["Apagar nota?"]
        XCTAssertTrue(deleteConfirmation.waitForExistence(timeout: 10), app.debugDescription)
        let dismissalRegion = identified("PopoverDismissRegion")
        XCTAssertTrue(dismissalRegion.waitForExistence(timeout: 10), app.debugDescription)
        dismissalRegion.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertFalse(deleteConfirmation.exists, app.debugDescription)
        XCTAssertTrue(app.webViews.staticTexts[nextFront].exists, app.debugDescription)

        activate(toolsButton)
        activate(revealStudyToolAction("deleteNote"))
        let confirmDelete = deleteConfirmation.buttons["Apagar nota"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 10), app.debugDescription)
        activate(confirmDelete)
        let closeStudy = identified("study.close")
        XCTAssertTrue(closeStudy.waitForExistence(timeout: 10), app.debugDescription)
        activate(closeStudy)
        let closeDeckOverview = identified("deck.overview.close")
        XCTAssertTrue(closeDeckOverview.waitForExistence(timeout: 10), app.debugDescription)
        activate(closeDeckOverview)
        navigate("Painel")
        XCTAssertTrue(app.navigationBars["Painel"].waitForExistence(timeout: 10), app.debugDescription)
        search("is:new \(nextFront)")
        XCTAssertTrue(app.staticTexts["Nenhum cartão"].waitForExistence(timeout: 10), app.debugDescription)
        button("Desfazer")
        search("is:new \(nextFront)")
        XCTAssertTrue(app.staticTexts[nextFront].waitForExistence(timeout: 10), app.debugDescription)
        search("is:new \(currentFront)")
        XCTAssertTrue(app.staticTexts[currentFront].waitForExistence(timeout: 10), app.debugDescription)

        let buriedFront = "UI Study buried note"
        let suspendedFront = "UI Study suspended note"
        addNote(front: buriedFront, back: "UI Study buried response")
        addNote(front: suspendedFront, back: "UI Study suspended response")
        navigate("Baralhos")
        activate(app.buttons["deck.options.Default"])
        let newLimitMode = identified("deck.options.limitMode.new")
        XCTAssertTrue(newLimitMode.waitForExistence(timeout: 10), app.debugDescription)
        activate(newLimitMode)
        let todayMode = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Somente hoje")
        ).firstMatch
        XCTAssertTrue(todayMode.waitForExistence(timeout: 10), app.debugDescription)
        activate(todayMode)
        let todayNewLimit = identified("deck.options.limit.new.today")
        XCTAssertTrue(todayNewLimit.waitForExistence(timeout: 10), app.debugDescription)
        incrementStepper(todayNewLimit, times: 5)
        button("Salvar")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")

        let buriedCard = app.webViews.staticTexts[buriedFront].firstMatch
        for _ in 0..<6 {
            if buriedCard.exists { break }
            activate(identified("study.revealAnswer"))
            activate(identified("study.rating.3"))
        }
        XCTAssertTrue(buriedCard.waitForExistence(timeout: 10), app.debugDescription)
        activate(toolsButton)
        activate(revealStudyToolAction("buryNote"))
        activate(identified("study.tools.close"))
        activate(identified("study.close"))
        activate(identified("deck.overview.close"))
        navigate("Painel")
        search("is:buried")
        XCTAssertTrue(app.staticTexts[buriedFront].waitForExistence(timeout: 10), app.debugDescription)

        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        let suspendedCard = app.webViews.staticTexts[suspendedFront].firstMatch
        for _ in 0..<6 {
            if suspendedCard.exists { break }
            activate(identified("study.revealAnswer"))
            activate(identified("study.rating.3"))
        }
        XCTAssertTrue(suspendedCard.waitForExistence(timeout: 10), app.debugDescription)
        activate(toolsButton)
        activate(revealStudyToolAction("suspendNote"))
        activate(identified("study.tools.close"))
        activate(identified("study.close"))
        activate(identified("deck.overview.close"))
        navigate("Painel")
        search("is:suspended")
        XCTAssertTrue(app.staticTexts[suspendedFront].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testStudyToolsCanAdjustCardTextSizeAndPersist() {
        addNote(front: "UI Tools zoom question", back: "UI Tools zoom answer")
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")

        var cardArea = identified("study.cardArea")
        XCTAssertTrue(cardArea.waitForExistence(timeout: 10), app.debugDescription)
        var openStart = cardArea.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        var openEnd = cardArea.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        openStart.press(forDuration: 0.05, thenDragTo: openEnd)

        let zoomValue = identified("study.tools.cardZoom.value")
        XCTAssertTrue(zoomValue.waitForExistence(timeout: 10), app.debugDescription)
        let initialValue = zoomValue.value as? String ?? ""
        XCTAssertFalse(initialValue.isEmpty, app.debugDescription)
        activate(identified("study.tools.cardZoom.up"))
        let increasedValue = zoomValue.value as? String ?? ""
        XCTAssertNotEqual(increasedValue, initialValue, app.debugDescription)
        button("Fechar")

        app.terminate()
        app.launch()
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")

        cardArea = identified("study.cardArea")
        XCTAssertTrue(cardArea.waitForExistence(timeout: 10), app.debugDescription)
        openStart = cardArea.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        openEnd = cardArea.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        openStart.press(forDuration: 0.05, thenDragTo: openEnd)
        XCTAssertTrue(zoomValue.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(zoomValue.value as? String, increasedValue, app.debugDescription)
        activate(identified("study.tools.cardZoom.down"))
        XCTAssertEqual(zoomValue.value as? String, initialValue, app.debugDescription)
        button("Fechar")
    }

    func testStudyFrequentActionsCanBeAddedReorderedAndRemovedAfterRelaunch() {
        addNote(front: "UI Tools actions question", back: "UI Tools actions answer")
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")

        var cardArea = identified("study.cardArea")
        XCTAssertTrue(cardArea.waitForExistence(timeout: 10), app.debugDescription)
        var openStart = cardArea.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        var openEnd = cardArea.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        openStart.press(forDuration: 0.05, thenDragTo: openEnd)

        let addMark = identified("study.tools.add.mark")
        activate(addMark)
        let markAction = identified("study.tools.frequent.mark")
        XCTAssertTrue(markAction.waitForExistence(timeout: 5), app.debugDescription)

        let editActions = identified("study.tools.frequent.edit")
        activate(editActions)
        let removeMark = identified("study.tools.remove.mark")
        activate(removeMark)
        XCTAssertFalse(markAction.exists, app.debugDescription)
        let addMarkAgain = identified("study.tools.add.mark")
        activate(addMarkAgain)

        let moveMarkUp = identified("study.tools.frequent.moveUp.mark")
        activate(moveMarkUp)
        let undoAction = identified("study.tools.frequent.undo")
        XCTAssertLessThan(markAction.frame.minY, undoAction.frame.minY, app.debugDescription)
        button("Fechar")

        app.terminate()
        app.launch()
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")

        cardArea = identified("study.cardArea")
        XCTAssertTrue(cardArea.waitForExistence(timeout: 10), app.debugDescription)
        openStart = cardArea.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        openEnd = cardArea.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        openStart.press(forDuration: 0.05, thenDragTo: openEnd)
        XCTAssertTrue(markAction.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertLessThan(markAction.frame.minY, undoAction.frame.minY, app.debugDescription)

        activate(editActions)
        activate(removeMark)
        XCTAssertFalse(markAction.exists, app.debugDescription)
        button("Fechar")
    }

    func testStudyConfiguredTopBarActionAfterRelaunch() {
        addNote(front: "UI Top bar question", back: "UI Top bar answer")
        navigate("Ferramentas")
        button("Preferências do AnkiOS")

        let topBarAction = identified("preferences.topBar.action")
        reveal(topBarAction)
        activate(topBarAction)
        menuButton("Mostrar resposta", swipeDown: true)
        let showToolsButton = identified("preferences.topBar.showTools")
        XCTAssertTrue(showToolsButton.waitForExistence(timeout: 10), app.debugDescription)
        if "\(showToolsButton.value ?? "")" != "1" { activate(showToolsButton) }
        let toolsButtonOnLeft = identified("preferences.topBar.positionLeft")
        XCTAssertTrue(toolsButtonOnLeft.waitForExistence(timeout: 10), app.debugDescription)
        if "\(toolsButtonOnLeft.value ?? "")" != "0" { activate(toolsButtonOnLeft) }
        XCTAssertEqual("\(showToolsButton.value ?? "")", "1", app.debugDescription)
        XCTAssertEqual("\(toolsButtonOnLeft.value ?? "")", "0", app.debugDescription)
        button("Salvar preferências")

        app.terminate()
        app.launch()
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        XCTAssertEqual("\(identified("preferences.topBar.showTools").value ?? "")", "1", app.debugDescription)
        XCTAssertEqual("\(identified("preferences.topBar.positionLeft").value ?? "")", "0", app.debugDescription)
        activate(app.navigationBars.buttons.firstMatch)
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")

        let studyAction = identified("study.topBar.action")
        XCTAssertTrue(studyAction.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(studyAction.label, "Mostrar resposta", app.debugDescription)
        XCTAssertGreaterThan(studyAction.frame.minX, app.frame.width / 2, app.debugDescription)
        let rightToolsOverlay = identified("study.tools.overlay")
        XCTAssertTrue(rightToolsOverlay.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThan(rightToolsOverlay.frame.minX, app.frame.width / 2, app.debugDescription)
        activate(rightToolsOverlay)
        XCTAssertTrue(identified("study.tools.scroll").waitForExistence(timeout: 10), app.debugDescription)
        activate(identified("study.tools.close"))
        XCTAssertFalse(app.webViews.staticTexts["UI Top bar answer"].exists, app.debugDescription)
        activate(identified("study.close"))
        XCTAssertTrue(app.buttons["deck.overview.close"].waitForExistence(timeout: 10), app.debugDescription)
        activate(identified("deck.overview.close"))

        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let moveToolsButtonLeft = identified("preferences.topBar.positionLeft")
        XCTAssertTrue(moveToolsButtonLeft.waitForExistence(timeout: 10), app.debugDescription)
        if "\(moveToolsButtonLeft.value ?? "")" != "1" { activate(moveToolsButtonLeft) }
        XCTAssertEqual("\(moveToolsButtonLeft.value ?? "")", "1", app.debugDescription)
        button("Salvar preferências")

        app.terminate()
        app.launch()
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        XCTAssertEqual("\(identified("preferences.topBar.showTools").value ?? "")", "1", app.debugDescription)
        XCTAssertEqual("\(identified("preferences.topBar.positionLeft").value ?? "")", "1", app.debugDescription)
        activate(app.navigationBars.buttons.firstMatch)
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")

        let leftStudyAction = identified("study.topBar.action")
        XCTAssertTrue(leftStudyAction.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(leftStudyAction.label, "Mostrar resposta", app.debugDescription)
        XCTAssertGreaterThan(leftStudyAction.frame.minX, app.frame.width / 2, app.debugDescription)
        let leftToolsOverlay = identified("study.tools.overlay")
        XCTAssertTrue(leftToolsOverlay.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertLessThan(leftToolsOverlay.frame.minX, app.frame.width / 2, app.debugDescription)
        activate(leftToolsOverlay)
        XCTAssertTrue(identified("study.tools.scroll").waitForExistence(timeout: 10), app.debugDescription)
        activate(identified("study.tools.close"))
        XCTAssertFalse(app.webViews.staticTexts["UI Top bar answer"].exists, app.debugDescription)
        activate(leftStudyAction)
        XCTAssertTrue(app.webViews.staticTexts["UI Top bar answer"].waitForExistence(timeout: 10), app.debugDescription)

        activate(identified("study.close"))
        XCTAssertTrue(app.buttons["deck.overview.close"].waitForExistence(timeout: 10), app.debugDescription)
        activate(identified("deck.overview.close"))
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let hideToolsButton = identified("preferences.topBar.showTools")
        XCTAssertTrue(hideToolsButton.waitForExistence(timeout: 10), app.debugDescription)
        if "\(hideToolsButton.value ?? "")" != "0" { activate(hideToolsButton) }
        button("Salvar preferências")

        app.terminate()
        app.launch()
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        XCTAssertTrue(identified("study.topBar.action").exists, app.debugDescription)
        XCTAssertFalse(identified("study.tools.overlay").exists, app.debugDescription)
        activate(identified("study.topBar.action"))
        XCTAssertTrue(app.webViews.staticTexts["UI Top bar answer"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testStudyConfiguredSwipeActionsAfterRelaunch() {
        addNote(front: "UI Swipe question", back: "UI Swipe answer")
        navigate("Ferramentas")
        button("Preferências do AnkiOS")

        let swipeLeft = identified("preferences.swipe.left")
        XCTAssertTrue(swipeLeft.waitForExistence(timeout: 10), app.debugDescription)
        activate(swipeLeft)
        menuButton("Mostrar resposta", swipeDown: true)

        let shakeAction = identified("preferences.shake.action")
        XCTAssertTrue(shakeAction.waitForExistence(timeout: 10), app.debugDescription)
        reveal(shakeAction)
        activate(shakeAction)
        menuButton("Mostrar resposta", swipeDown: true)
        let feedbackTicks = identified("preferences.review.feedbackTicks")
        XCTAssertTrue(feedbackTicks.waitForExistence(timeout: 10), app.debugDescription)
        if "\(feedbackTicks.value ?? "")" != "0" { activate(feedbackTicks) }
        let audioBehavior = identified("preferences.review.duckIgnoreMute")
        XCTAssertTrue(audioBehavior.waitForExistence(timeout: 10), app.debugDescription)
        if "\(audioBehavior.value ?? "")" != "1" { activate(audioBehavior) }
        let neverTypeAnswer = identified("preferences.review.neverTypeAnswer")
        XCTAssertTrue(neverTypeAnswer.waitForExistence(timeout: 10), app.debugDescription)
        if "\(neverTypeAnswer.value ?? "")" != "1" { activate(neverTypeAnswer) }
        activate(identified("preferences.save"))

        app.terminate()
        app.launch()
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let savedShakeAction = identified("preferences.shake.action")
        XCTAssertTrue(savedShakeAction.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(
            "\(savedShakeAction.label) \(savedShakeAction.value ?? "")".localizedCaseInsensitiveContains("Mostrar resposta"),
            app.debugDescription
        )
        XCTAssertEqual("\(identified("preferences.review.feedbackTicks").value ?? "")", "0", app.debugDescription)
        XCTAssertEqual("\(identified("preferences.review.duckIgnoreMute").value ?? "")", "1", app.debugDescription)
        XCTAssertEqual("\(identified("preferences.review.neverTypeAnswer").value ?? "")", "1", app.debugDescription)
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")

        let cardArea = identified("study.cardArea")
        XCTAssertTrue(cardArea.waitForExistence(timeout: 10), app.debugDescription)
        let start = cardArea.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        let end = cardArea.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.webViews.staticTexts["UI Swipe answer"].waitForExistence(timeout: 10), app.debugDescription)

        let returnStart = cardArea.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let returnEnd = cardArea.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        returnStart.press(forDuration: 0.05, thenDragTo: returnEnd)
        XCTAssertTrue(app.buttons["deck.overview.close"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["Mostrar resposta"].exists, app.debugDescription)
    }

    func testStudyConfiguredCardTapRatesCardAfterRelaunch() {
        let zoomDeck = "UI Zoom \(UUID().uuidString.prefix(8))"
        createDeck(zoomDeck)
        addNote(front: "UI Tap question", back: "UI Tap answer", deckName: zoomDeck)
        navigate("Ferramentas")
        button("Preferências do AnkiOS")

        let answerSection = app.staticTexts["Resposta exibida"].firstMatch
        reveal(answerSection)
        XCTAssertTrue(answerSection.isHittable, app.debugDescription)
        let answerCenter = identified("preferences.tap.answer.middleCenter")
        XCTAssertTrue(answerCenter.waitForExistence(timeout: 10), app.debugDescription)
        activate(answerCenter)
        menuButton("Bom", swipeDown: true)
        let doubleTapPrevention = identified("preferences.review.doubleTapPrevention")
        XCTAssertTrue(doubleTapPrevention.waitForExistence(timeout: 10), app.debugDescription)
        if "\(doubleTapPrevention.value ?? "")" != "1" { activate(doubleTapPrevention) }
        let doubleTapDelay = identified("preferences.review.doubleTapDelay")
        XCTAssertTrue(doubleTapDelay.waitForExistence(timeout: 10), app.debugDescription)
        doubleTapDelay.adjust(toNormalizedSliderPosition: 1.0)
        let answerKeepsZoom = identified("preferences.review.answerKeepsZoom")
        revealPreferenceElement(answerKeepsZoom)
        setToggle(answerKeepsZoom, to: true)
        XCTAssertEqual(answerKeepsZoom.value as? String, "1", app.debugDescription)
        activate(identified("preferences.save"))

        app.terminate()
        app.launch()
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let reloadedAnswerKeepsZoom = identified("preferences.review.answerKeepsZoom")
        XCTAssertTrue(reloadedAnswerKeepsZoom.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(reloadedAnswerKeepsZoom.value as? String, "1", app.debugDescription)
        activate(app.navigationBars.buttons.firstMatch)
        navigate("Baralhos")
        activate(app.buttons["deck.open.\(zoomDeck)"])
        button("Estudar agora")
        let cardArea = identified("study.cardArea")
        XCTAssertTrue(cardArea.waitForExistence(timeout: 10), app.debugDescription)
        let question = app.webViews.staticTexts["UI Tap question"]
        XCTAssertTrue(question.waitForExistence(timeout: 10), app.debugDescription)
        let cardWebView = app.webViews.firstMatch
        let webViewWidthAtDefaultZoom = cardWebView.frame.width
        XCTAssertTrue(pinchUntilWidth(cardArea, observing: cardWebView, exceeds: webViewWidthAtDefaultZoom * 1.1), app.debugDescription)
        activate(identified("study.revealAnswer"))
        XCTAssertTrue(app.webViews.staticTexts["UI Tap answer"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitForWidth(cardWebView, timeout: 5) { $0 > webViewWidthAtDefaultZoom * 1.1 }, app.debugDescription)
        XCTAssertTrue(waitForStudyProgress(prefix: "0 feitos", timeout: 5), app.debugDescription)
        activate(identified("study.rating.3"))
        XCTAssertTrue(waitForStudyProgress(prefix: "1 feitos", timeout: 15), app.debugDescription)
        XCTAssertTrue(app.webViews.staticTexts["UI Tap question"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.webViews.staticTexts["UI Tap answer"].exists, app.debugDescription)
        activate(identified("study.moreMenu"))
        menuButton("Desfazer", swipeDown: true)
        XCTAssertTrue(identified("study.revealAnswer").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(question.waitForExistence(timeout: 10), app.debugDescription)

        activate(identified("study.close"))
        activate(identified("deck.overview.close"))
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let revisionSection = app.staticTexts["Revisão"].firstMatch
        reveal(revisionSection)
        XCTAssertTrue(revisionSection.isHittable, app.debugDescription)
        let answerResetsZoom = identified("preferences.review.answerKeepsZoom")
        revealPreferenceElement(answerResetsZoom)
        setToggle(answerResetsZoom, to: false)
        XCTAssertEqual(answerResetsZoom.value as? String, "0", app.debugDescription)
        activate(identified("preferences.save"))

        navigate("Baralhos")
        activate(app.buttons["deck.open.\(zoomDeck)"])
        button("Estudar agora")
        let resetQuestion = app.webViews.staticTexts["UI Tap question"]
        XCTAssertTrue(resetQuestion.waitForExistence(timeout: 10), app.debugDescription)
        let resetCardWebView = app.webViews.firstMatch
        let resetWebViewDefaultWidth = resetCardWebView.frame.width
        XCTAssertTrue(pinchUntilWidth(cardArea, observing: resetCardWebView, exceeds: resetWebViewDefaultWidth * 1.1), app.debugDescription)
        activate(identified("study.revealAnswer"))
        let resetAnswer = app.webViews.staticTexts["UI Tap answer"]
        XCTAssertTrue(resetAnswer.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitForWidth(resetCardWebView, timeout: 5) { $0 < resetWebViewDefaultWidth * 1.1 }, app.debugDescription)
    }

    func testStudyScratchpadPreferencesPersistAndApply() {
        addNote(front: "UI Scratchpad preferences question", back: "UI Scratchpad preferences answer")
        navigate("Ferramentas")
        button("Preferências do AnkiOS")

        let ignoreFingers = identified("preferences.scratchpad.ignoreFingers")
        let undoClearsAll = identified("preferences.scratchpad.undoClearsAll")
        let belowButtons = identified("preferences.scratchpad.belowButtons")
        revealPreferenceElement(ignoreFingers)
        revealPreferenceElement(undoClearsAll)
        revealPreferenceElement(belowButtons)
        setToggle(ignoreFingers, to: true)
        setToggle(undoClearsAll, to: true)
        setToggle(belowButtons, to: true)
        XCTAssertEqual("\(ignoreFingers.value ?? "")", "1", app.debugDescription)
        XCTAssertEqual("\(undoClearsAll.value ?? "")", "1", app.debugDescription)
        XCTAssertEqual("\(belowButtons.value ?? "")", "1", app.debugDescription)
        activate(identified("preferences.save"))

        app.terminate()
        app.launch()
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        XCTAssertEqual("\(identified("preferences.scratchpad.ignoreFingers").value ?? "")", "1", app.debugDescription)
        XCTAssertEqual("\(identified("preferences.scratchpad.undoClearsAll").value ?? "")", "1", app.debugDescription)
        XCTAssertEqual("\(identified("preferences.scratchpad.belowButtons").value ?? "")", "1", app.debugDescription)
        activate(app.navigationBars.buttons.firstMatch)
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")

        let toolsButton = identified("study.topBar.action")
        XCTAssertTrue(toolsButton.waitForExistence(timeout: 10), app.debugDescription)
        activate(toolsButton)
        let scratchpadAction = identified("study.tools.action.scratchpad")
        XCTAssertTrue(scratchpadAction.waitForExistence(timeout: 10), app.debugDescription)
        if scratchpadAction.value as? String != "Ativado" { activate(scratchpadAction) }
        activate(identified("study.tools.close"))
        let scratchpadCanvas = identified("study.scratchpad.canvas")
        XCTAssertTrue(scratchpadCanvas.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(scratchpadCanvas.label, "Área do bloco de escrita, somente Apple Pencil", app.debugDescription)
        XCTAssertEqual(scratchpadCanvas.value as? String, "0 traços", app.debugDescription)
        let fingerStart = scratchpadCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.42))
        let fingerEnd = scratchpadCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.42))
        fingerStart.press(forDuration: 0.05, thenDragTo: fingerEnd)
        XCTAssertEqual(scratchpadCanvas.value as? String, "0 traços", app.debugDescription)

        activate(identified("study.close"))
        activate(identified("deck.overview.close"))
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let ignoreFingersForDrawing = identified("preferences.scratchpad.ignoreFingers")
        setToggle(ignoreFingersForDrawing, to: false)
        XCTAssertEqual("\(ignoreFingersForDrawing.value ?? "")", "0", app.debugDescription)
        activate(identified("preferences.save"))
        activate(app.navigationBars.buttons.firstMatch)
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        let immediateCanvas = identified("study.scratchpad.canvas")
        XCTAssertTrue(immediateCanvas.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(immediateCanvas.label, "Área do bloco de escrita, toque ou Apple Pencil", app.debugDescription)
        let immediateStart = immediateCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.42))
        let immediateEnd = immediateCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.42))
        immediateStart.press(forDuration: 0.05, thenDragTo: immediateEnd)
        let immediateStroke = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1 traços"),
            object: immediateCanvas
        )
        XCTAssertEqual(XCTWaiter.wait(for: [immediateStroke], timeout: 5), .completed, app.debugDescription)
        activate(identified("study.close"))
        activate(identified("deck.overview.close"))
        app.terminate()
        app.launch()
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        let scratchpad = identified("study.scratchpad")
        XCTAssertTrue(scratchpad.waitForExistence(timeout: 10), app.debugDescription)
        let drawingCanvas = identified("study.scratchpad.canvas")
        XCTAssertEqual(drawingCanvas.label, "Área do bloco de escrita, toque ou Apple Pencil", app.debugDescription)
        activate(identified("study.revealAnswer"))
        let goodButton = identified("study.rating.3")
        XCTAssertTrue(goodButton.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThan(scratchpad.frame.minY, goodButton.frame.maxY, app.debugDescription)

        let waitForScratchpadStrokeCount: (Int) -> Bool = { count in
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "\(count) traços"),
                object: drawingCanvas
            )
            return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
        }
        let firstStart = drawingCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.42))
        let firstEnd = drawingCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.42))
        firstStart.press(forDuration: 0.05, thenDragTo: firstEnd)
        XCTAssertTrue(waitForScratchpadStrokeCount(1), app.debugDescription)
        let secondStart = drawingCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.68))
        let secondEnd = drawingCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.68))
        secondStart.press(forDuration: 0.05, thenDragTo: secondEnd)
        XCTAssertTrue(waitForScratchpadStrokeCount(2), app.debugDescription)
        activate(identified("study.scratchpad.undo"))
        XCTAssertTrue(waitForScratchpadStrokeCount(0), app.debugDescription)

        let thirdStart = drawingCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
        let thirdEnd = drawingCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3))
        thirdStart.press(forDuration: 0.05, thenDragTo: thirdEnd)
        XCTAssertTrue(waitForScratchpadStrokeCount(1), app.debugDescription)
        let fourthStart = drawingCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.54))
        let fourthEnd = drawingCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.54))
        fourthStart.press(forDuration: 0.05, thenDragTo: fourthEnd)
        XCTAssertTrue(waitForScratchpadStrokeCount(2), app.debugDescription)
        identified("study.scratchpad.undo").press(forDuration: 1.2)
        XCTAssertTrue(waitForScratchpadStrokeCount(1), app.debugDescription)

        activate(identified("study.close"))
        activate(identified("deck.overview.close"))
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let restoreIgnoreFingers = identified("preferences.scratchpad.ignoreFingers")
        let restoreUndoClearsAll = identified("preferences.scratchpad.undoClearsAll")
        let restoreBelowButtons = identified("preferences.scratchpad.belowButtons")
        setToggle(restoreIgnoreFingers, to: false)
        setToggle(restoreUndoClearsAll, to: false)
        setToggle(restoreBelowButtons, to: false)
        activate(identified("preferences.save"))
    }

    func testStudyBottomBarPreferencesPersistAfterRelaunch() {
        addNote(front: "UI Bottom bar question", back: "UI Bottom bar answer")
        navigate("Ferramentas")
        button("Preferências do AnkiOS")

        let topBarAction = identified("preferences.topBar.action")
        reveal(topBarAction)
        activate(topBarAction)
        menuButton("Mostrar resposta", swipeDown: true)
        let toolsButton = identified("preferences.topBar.showTools")
        if "\(toolsButton.value ?? "")" != "1" { activate(toolsButton) }
        let toolsButtonOnLeft = identified("preferences.topBar.positionLeft")
        if "\(toolsButtonOnLeft.value ?? "")" != "0" { activate(toolsButtonOnLeft) }

        let remainingCount = identified("preferences.bottomBar.remainingCount")
        let answerButtons = identified("preferences.bottomBar.answerButtons")
        let nextTimes = identified("preferences.bottomBar.nextTimes")
        XCTAssertTrue(remainingCount.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(answerButtons.exists, app.debugDescription)
        XCTAssertTrue(nextTimes.exists, app.debugDescription)
        if "\(remainingCount.value ?? "")" != "1" { activate(remainingCount) }
        if "\(answerButtons.value ?? "")" != "1" { activate(answerButtons) }
        if "\(nextTimes.value ?? "")" != "0" { activate(nextTimes) }
        activate(identified("preferences.save"))

        app.terminate()
        app.launch()
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        XCTAssertEqual("\(identified("preferences.bottomBar.show").value ?? "")", "1", app.debugDescription)
        XCTAssertEqual("\(identified("preferences.bottomBar.remainingCount").value ?? "")", "1", app.debugDescription)
        XCTAssertEqual("\(identified("preferences.bottomBar.answerButtons").value ?? "")", "1", app.debugDescription)
        XCTAssertEqual("\(identified("preferences.bottomBar.nextTimes").value ?? "")", "0", app.debugDescription)
        activate(app.navigationBars.buttons.firstMatch)
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")

        let bottomBar = identified("study.bottomBar")
        XCTAssertTrue(bottomBar.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(bottomBar.staticTexts["Novo"].exists, app.debugDescription)
        XCTAssertTrue(bottomBar.staticTexts["Aprender"].exists, app.debugDescription)

        let toolsOverlay = identified("study.tools.overlay")
        activate(toolsOverlay)
        let bottomBarAction = identified("study.tools.action.toggleBottomBar")
        XCTAssertTrue(bottomBarAction.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(bottomBarAction.value as? String, "Visível", app.debugDescription)
        activate(bottomBarAction)
        XCTAssertEqual(bottomBarAction.value as? String, "Oculta", app.debugDescription)
        activate(identified("study.tools.close"))
        XCTAssertFalse(bottomBar.exists, app.debugDescription)
        activate(toolsOverlay)
        XCTAssertEqual(bottomBarAction.value as? String, "Oculta", app.debugDescription)
        activate(bottomBarAction)
        activate(identified("study.tools.close"))
        XCTAssertTrue(bottomBar.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(identified("study.topBar.action").label, "Mostrar resposta", app.debugDescription)
        activate(identified("study.topBar.action"))
        XCTAssertTrue(app.webViews.staticTexts["UI Bottom bar answer"].waitForExistence(timeout: 10), app.debugDescription)
        let goodButton = identified("study.rating.3")
        XCTAssertTrue(goodButton.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(goodButton.label.localizedCaseInsensitiveContains("min"), app.debugDescription)
        XCTAssertFalse(bottomBar.staticTexts["Novo"].exists, app.debugDescription)
        XCTAssertFalse(bottomBar.staticTexts["Aprender"].exists, app.debugDescription)

        activate(identified("study.close"))
        activate(identified("deck.overview.close"))
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let showBottomBar = identified("preferences.bottomBar.show")
        let showAnswerButtons = identified("preferences.bottomBar.answerButtons")
        let hideRemainingCount = identified("preferences.bottomBar.remainingCount")
        if "\(showBottomBar.value ?? "")" != "0" { activate(showBottomBar) }
        if "\(showAnswerButtons.value ?? "")" != "0" { activate(showAnswerButtons) }
        if "\(hideRemainingCount.value ?? "")" != "0" { activate(hideRemainingCount) }
        activate(identified("preferences.save"))

        app.terminate()
        app.launch()
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        XCTAssertEqual("\(identified("preferences.bottomBar.show").value ?? "")", "0", app.debugDescription)
        XCTAssertEqual("\(identified("preferences.bottomBar.answerButtons").value ?? "")", "0", app.debugDescription)
        XCTAssertEqual("\(identified("preferences.bottomBar.remainingCount").value ?? "")", "0", app.debugDescription)
        activate(app.navigationBars.buttons.firstMatch)
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        XCTAssertFalse(identified("study.bottomBar").exists, app.debugDescription)
        activate(identified("study.tools.overlay"))
        let hiddenBottomBarAction = identified("study.tools.action.toggleBottomBar")
        XCTAssertEqual(hiddenBottomBarAction.value as? String, "Oculta", app.debugDescription)
        activate(hiddenBottomBarAction)
        activate(identified("study.tools.close"))
        let restoredBottomBar = identified("study.bottomBar")
        XCTAssertTrue(restoredBottomBar.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(restoredBottomBar.staticTexts["Novo"].exists, app.debugDescription)
        XCTAssertFalse(restoredBottomBar.staticTexts["Aprender"].exists, app.debugDescription)
        XCTAssertFalse(identified("study.rating.3").exists, app.debugDescription)
        activate(identified("study.topBar.action"))
        XCTAssertTrue(app.webViews.staticTexts["UI Bottom bar answer"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(identified("study.rating.3").exists, app.debugDescription)

        activate(identified("study.close"))
        activate(identified("deck.overview.close"))
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let restoreBottomBar = identified("preferences.bottomBar.show")
        let restoreAnswerButtons = identified("preferences.bottomBar.answerButtons")
        let restoreRemainingCount = identified("preferences.bottomBar.remainingCount")
        let restoreNextTimes = identified("preferences.bottomBar.nextTimes")
        if "\(restoreBottomBar.value ?? "")" != "1" { activate(restoreBottomBar) }
        if "\(restoreAnswerButtons.value ?? "")" != "1" { activate(restoreAnswerButtons) }
        if "\(restoreRemainingCount.value ?? "")" != "1" { activate(restoreRemainingCount) }
        if "\(restoreNextTimes.value ?? "")" != "1" { activate(restoreNextTimes) }
        let restoreTopBarAction = identified("preferences.topBar.action")
        reveal(restoreTopBarAction)
        activate(restoreTopBarAction)
        menuButton("Abrir ferramentas", swipeDown: true)
        activate(identified("preferences.save"))
    }

    func testStudyToolsActionsRouteAndToggleDisplay() {
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let userActionScript = "var userJs1 = function(){document.body.innerText='USER ACTION FIRED';};"
        let userActionField = identified("preferences.userAction.1")
        activate(userActionField)
        userActionField.typeText(userActionScript)
        activate(identified("preferences.save"))
        activate(app.navigationBars.buttons.firstMatch)
        navigate("Baralhos")

        addNote(front: "UI Display controls question", back: "UI Display controls answer")
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")

        let toolsButton = identified("study.topBar.action")
        activate(toolsButton)

        let bottomBarAction = identified("study.tools.action.toggleBottomBar")
        XCTAssertTrue(bottomBarAction.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(bottomBarAction.value as? String, "Visível", app.debugDescription)
        activate(bottomBarAction)
        XCTAssertEqual(bottomBarAction.value as? String, "Oculta", app.debugDescription)
        button("Fechar")
        XCTAssertFalse(identified("study.bottomBar").exists, app.debugDescription)

        activate(toolsButton)
        activate(bottomBarAction)
        XCTAssertEqual(bottomBarAction.value as? String, "Visível", app.debugDescription)
        button("Fechar")
        XCTAssertTrue(identified("study.bottomBar").waitForExistence(timeout: 5), app.debugDescription)

        activate(toolsButton)
        let topBarAction = identified("study.tools.action.toggleTopBar")
        XCTAssertTrue(topBarAction.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(topBarAction.value as? String, "Visível", app.debugDescription)
        activate(topBarAction)
        XCTAssertEqual(topBarAction.value as? String, "Oculta", app.debugDescription)
        button("Fechar")
        XCTAssertFalse(toolsButton.exists, app.debugDescription)
        XCTAssertFalse(identified("study.progress").exists, app.debugDescription)

        let cardArea = identified("study.cardArea")
        let start = cardArea.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        let end = cardArea.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(topBarAction.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(topBarAction.value as? String, "Oculta", app.debugDescription)
        activate(topBarAction)
        XCTAssertEqual(topBarAction.value as? String, "Visível", app.debugDescription)
        button("Fechar")
        XCTAssertTrue(toolsButton.waitForExistence(timeout: 5), app.debugDescription)

        activate(toolsButton)
        let userAction = revealStudyToolAction("userAction1")
        activate(userAction)
        button("Fechar")
        XCTAssertTrue(app.webViews.staticTexts["USER ACTION FIRED"].waitForExistence(timeout: 10), app.debugDescription)

        activate(toolsButton)
        let scrollUp = revealStudyToolAction("scrollUp")
        let initialScrollRequest = scrollUp.value as? String
        activate(scrollUp)
        XCTAssertNotEqual(scrollUp.value as? String, initialScrollRequest, app.debugDescription)
        let scrollDown = revealStudyToolAction("scrollDown")
        let scrollRequestAfterUp = scrollDown.value as? String
        activate(scrollDown)
        XCTAssertNotEqual(scrollDown.value as? String, scrollRequestAfterUp, app.debugDescription)
        button("Fechar")

        let initialScratchpadValue: String
        activate(toolsButton)
        let scratchpadAction = revealStudyToolAction("scratchpad")
        initialScratchpadValue = scratchpadAction.value as? String ?? "Desativado"
        if initialScratchpadValue == "Ativado" {
            activate(scratchpadAction)
            XCTAssertEqual(scratchpadAction.value as? String, "Desativado", app.debugDescription)
        }
        activate(scratchpadAction)
        XCTAssertEqual(scratchpadAction.value as? String, "Ativado", app.debugDescription)
        let scratchpadSizeAction = revealStudyToolAction("scratchpadSize")
        let initialScratchpadSize = scratchpadSizeAction.value as? String
        activate(scratchpadSizeAction)
        XCTAssertNotEqual(scratchpadSizeAction.value as? String, initialScratchpadSize, app.debugDescription)
        for _ in 0..<2 where scratchpadSizeAction.value as? String != initialScratchpadSize {
            activate(scratchpadSizeAction)
        }
        XCTAssertEqual(scratchpadSizeAction.value as? String, initialScratchpadSize, app.debugDescription)
        button("Fechar")
        let scratchpadCanvas = identified("study.scratchpad.canvas")
        XCTAssertTrue(scratchpadCanvas.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(scratchpadCanvas.value as? String, "0 traços", app.debugDescription)
        let waitForScratchpadStrokeCount: (Int) -> Bool = { count in
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "\(count) traços"),
                object: scratchpadCanvas
            )
            return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
        }
        let firstStrokeStart = scratchpadCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.42))
        let firstStrokeEnd = scratchpadCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.42))
        firstStrokeStart.press(forDuration: 0.05, thenDragTo: firstStrokeEnd)
        XCTAssertTrue(waitForScratchpadStrokeCount(1), app.debugDescription)
        activate(identified("study.scratchpad.undo"))
        XCTAssertTrue(waitForScratchpadStrokeCount(0), app.debugDescription)
        let secondStrokeStart = scratchpadCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.68))
        let secondStrokeEnd = scratchpadCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.68))
        secondStrokeStart.press(forDuration: 0.05, thenDragTo: secondStrokeEnd)
        XCTAssertTrue(waitForScratchpadStrokeCount(1), app.debugDescription)
        let thirdStrokeStart = scratchpadCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.84))
        let thirdStrokeEnd = scratchpadCanvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.84))
        thirdStrokeStart.press(forDuration: 0.05, thenDragTo: thirdStrokeEnd)
        XCTAssertTrue(waitForScratchpadStrokeCount(2), app.debugDescription)
        identified("study.scratchpad.undo").press(forDuration: 1.2)
        XCTAssertTrue(waitForScratchpadStrokeCount(0), app.debugDescription)

        app.terminate()
        app.launch()
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        XCTAssertTrue(identified("study.scratchpad.canvas").waitForExistence(timeout: 10), app.debugDescription)
        activate(toolsButton)
        XCTAssertEqual(revealStudyToolAction("scratchpadSize").value as? String, initialScratchpadSize, app.debugDescription)
        button("Fechar")

        activate(toolsButton)
        activate(revealStudyToolAction("scratchpad"))
        XCTAssertEqual(identified("study.tools.action.scratchpad").value as? String, "Desativado", app.debugDescription)
        button("Fechar")
        XCTAssertFalse(identified("study.scratchpad.canvas").exists, app.debugDescription)
        if initialScratchpadValue == "Ativado" {
            activate(toolsButton)
            activate(revealStudyToolAction("scratchpad"))
            button("Fechar")
        }

        activate(toolsButton)
        let nightModeAction = identified("study.tools.action.toggleNightMode")
        XCTAssertTrue(nightModeAction.waitForExistence(timeout: 10), app.debugDescription)
        let startingMode = nightModeAction.value as? String
        XCTAssertNotNil(startingMode, app.debugDescription)
        activate(nightModeAction)
        XCTAssertNotEqual(nightModeAction.value as? String, startingMode, app.debugDescription)
        activate(nightModeAction)
        XCTAssertEqual(nightModeAction.value as? String, startingMode, app.debugDescription)
        button("Fechar")

        activate(toolsButton)
        let browseAction = revealStudyToolAction("browse")
        activate(browseAction)
        XCTAssertTrue(app.navigationBars["Painel"].waitForExistence(timeout: 10), app.debugDescription)
        button("Fechar")
        XCTAssertTrue(toolsButton.waitForExistence(timeout: 5), app.debugDescription)

        activate(toolsButton)
        let addAction = identified("study.tools.action.add")
        XCTAssertTrue(addAction.waitForExistence(timeout: 10), app.debugDescription)
        activate(addAction)
        XCTAssertTrue(app.navigationBars["Adicionar"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(identified("add.source").waitForExistence(timeout: 10), app.debugDescription)
        button("Fechar")

        activate(toolsButton)
        activate(revealStudyToolAction("studyOptions"))
        XCTAssertTrue(app.navigationBars["Opções do Baralho"].waitForExistence(timeout: 10), app.debugDescription)
        activate(identified("deck.options.close"))

        activate(toolsButton)
        activate(revealStudyToolAction("customStudy"))
        XCTAssertTrue(app.navigationBars["Estudo Personalizado"].waitForExistence(timeout: 10), app.debugDescription)
        activate(identified("customStudy.cancel"))

        activate(toolsButton)
        activate(revealStudyToolAction("deckStatistics"))
        XCTAssertTrue(app.navigationBars["Estatísticas"].waitForExistence(timeout: 10), app.debugDescription)
        activate(identified("stats.close"))

        activate(toolsButton)
        activate(revealStudyToolAction("cardTemplate"))
        XCTAssertTrue(app.navigationBars["Editar tipo de nota"].waitForExistence(timeout: 10), app.debugDescription)
        activate(identified("notetype.editor.cancel"))

        activate(toolsButton)
        activate(revealStudyToolAction("decks"))
        XCTAssertTrue(app.buttons["deck.open.Default"].waitForExistence(timeout: 15), app.debugDescription)
    }
    #endif

    func testStudyAutoAdvanceRevealsAnswer() {
        addNote()
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        let moreMenu = identified("study.moreMenu")
        XCTAssertTrue(moreMenu.waitForExistence(timeout: 10), app.debugDescription)
        activate(moreMenu)
        menuButton("Configurar avanço automático…", swipeDown: true)

        let questionSeconds = identified("autoAdvance.questionSeconds")
        XCTAssertTrue(questionSeconds.waitForExistence(timeout: 10), app.debugDescription)
        incrementStepper(questionSeconds)
        XCTAssertTrue(String(describing: questionSeconds.value ?? "").contains("1"), app.debugDescription)

        let answerSeconds = identified("autoAdvance.answerSeconds")
        XCTAssertTrue(answerSeconds.waitForExistence(timeout: 10), app.debugDescription)
        incrementStepper(answerSeconds, times: 5)
        XCTAssertTrue(String(describing: answerSeconds.value ?? "").contains("5"), app.debugDescription)
        activate(identified("autoAdvance.save"))

        activate(moreMenu)
        menuButton("Iniciar avanço automático", swipeDown: true)
        XCTAssertTrue(app.webViews.staticTexts["UI answer"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Parabéns! Você terminou este baralho por enquanto."].waitForExistence(timeout: 10))
    }

    func testStudyAutoAdvanceStopsAfterAppLosesFocus() async throws {
        #if os(iOS)
        addNote()
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        let moreMenu = identified("study.moreMenu")
        XCTAssertTrue(moreMenu.waitForExistence(timeout: 10), app.debugDescription)
        activate(moreMenu)
        menuButton("Configurar avanço automático…", swipeDown: true)

        let questionSeconds = identified("autoAdvance.questionSeconds")
        XCTAssertTrue(questionSeconds.waitForExistence(timeout: 10), app.debugDescription)
        incrementStepper(questionSeconds, times: 5)
        XCTAssertTrue((questionSeconds.value as? String)?.contains("5") == true, app.debugDescription)
        activate(identified("autoAdvance.save"))

        activate(moreMenu)
        menuButton("Iniciar avanço automático", swipeDown: true)
        XCUIDevice.shared.press(.home)
        try await Task.sleep(nanoseconds: 7_000_000_000)
        app.activate()

        let question = app.webViews.staticTexts["UI question"].firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.webViews.staticTexts["UI answer"].firstMatch.exists, app.debugDescription)
        #else
        throw XCTSkip("Este cenário exercita o segundo plano no iOS.")
        #endif
    }

    func testStudyAutoAdvanceSkipsTimeoutWhenAudioIsPlaying() async throws {
        let package = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "official", withExtension: "apkg"))
        app.open(package)
        button("Importar")
        if app.buttons["Importar"].firstMatch.waitForExistence(timeout: 5) {
            button("Importar")
        }
        finishTutorialIfPresented()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 30))
        button("OK")
        finishTutorialIfPresented()
        activate(app.buttons["deck.open.UI Imported"])
        button("Estudar agora")
        let moreMenu = identified("study.moreMenu")
        XCTAssertTrue(moreMenu.waitForExistence(timeout: 10), app.debugDescription)
        activate(moreMenu)
        menuButton("Configurar avanço automático…", swipeDown: true)

        let waitForAudio = identified("autoAdvance.waitForAudio")
        XCTAssertTrue(waitForAudio.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(waitForAudio.value as? String, "1", app.debugDescription)
        let questionSeconds = identified("autoAdvance.questionSeconds")
        XCTAssertTrue(questionSeconds.waitForExistence(timeout: 10), app.debugDescription)
        incrementStepper(questionSeconds)
        XCTAssertTrue((questionSeconds.value as? String)?.contains("1") == true, app.debugDescription)
        let answerSeconds = identified("autoAdvance.answerSeconds")
        XCTAssertTrue(answerSeconds.waitForExistence(timeout: 10), app.debugDescription)
        incrementStepper(answerSeconds)
        XCTAssertTrue((answerSeconds.value as? String)?.contains("1") == true, app.debugDescription)
        activate(identified("autoAdvance.save"))

        activate(moreMenu)
        menuButton("Iniciar avanço automático", swipeDown: true)

        let answer = app.webViews.staticTexts["UI imported answer"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5), app.debugDescription)
        activate(moreMenu)
        let audioToggle = identified("study.audio.toggle")
        for _ in 0..<8 {
            if audioToggle.exists && audioToggle.isHittable { break }
            if app.collectionViews.firstMatch.exists {
                app.collectionViews.firstMatch.swipeDown()
            } else {
                app.swipeDown()
            }
        }
        XCTAssertTrue(audioToggle.exists, app.debugDescription)
        XCTAssertTrue(audioToggle.label.contains("Pausar áudio"), app.debugDescription)

        menuButton("Replay áudio", swipeDown: true)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertTrue(answer.exists, app.debugDescription)
        let answerHidden = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: answer
        )
        await fulfillment(of: [answerHidden], timeout: 45)
    }

    func testStudyKeyboardSpaceAndRating() {
        addNote()
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        app.typeKey(XCUIKeyboardKey.space, modifierFlags: [])
        #if os(macOS)
        XCTAssertTrue(app.buttons["study.rating.3"].waitForExistence(timeout: 10), app.debugDescription)
        #else
        XCTAssertTrue(app.webViews.staticTexts["UI answer"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["study.rating.3"].waitForExistence(timeout: 5), app.debugDescription)
        #endif
        let progress = studyProgress()
        XCTAssertTrue(progress.waitForExistence(timeout: 5), app.debugDescription)
        let progressValue = progress.value as? String ?? progress.label
        let nextCount = (Int(progressValue.split(separator: " ").first ?? "0") ?? 0) + 1
#if os(iOS)
        let menu = identified("study.moreMenu")
        activate(menu)
        let hideCard = menuButton("Ocultar cartão", select: false)
        XCTAssertTrue(hideCard.exists && hideCard.isHittable, app.debugDescription)
        app.typeKey("3", modifierFlags: [])
        XCTAssertTrue(
            waitForStudyProgress(prefix: "\(nextCount) feitos", timeout: 10),
            "Esperava o atalho 3 avaliar o cartão com o menu aberto.\n\(app.debugDescription)"
        )
#else
        app.typeKey("3", modifierFlags: [])
        XCTAssertTrue(
            waitForStudyProgress(prefix: "\(nextCount) feitos", timeout: 10),
            "Esperava \(nextCount) feitos após a avaliação.\n\(app.debugDescription)"
        )
#endif
    }

    func testStudyRatingShortcutsCoverAllGrades() {
        for index in 1...4 {
            addNote(front: "Keyboard question \(index)", back: "Keyboard answer \(index)")
        }
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")

        for rating in 1...4 {
            activate(identified("study.revealAnswer"))
            XCTAssertTrue(identified("study.rating.\(rating)").waitForExistence(timeout: 10), app.debugDescription)
            app.typeKey(String(rating), modifierFlags: [])
#if os(iOS)
            if rating == 1 {
                XCTAssertTrue(identified("study.answerFeedback").waitForExistence(timeout: 5), app.debugDescription)
            }
#endif
            XCTAssertTrue(
                waitForStudyProgress(prefix: "\(rating) feitos", timeout: 10),
                "Esperava \(rating) feitos após a nota \(rating).\n\(app.debugDescription)"
            )
        }
    }

#if os(iOS)
    private func verifyInfoForAddingConsumer() throws {
        let infoComponents = URLComponents(string: "anki://x-callback-url/infoForAdding?x-success=ankios-info-consumer://return")!
        let pasteboardChangeCount = UIPasteboard.general.changeCount
        openAnkiURL(infoComponents.url!)
        let allowInfo = app.buttons["Permitir"]
        XCTAssertTrue(allowInfo.waitForExistence(timeout: 10), app.debugDescription)
        activate(allowInfo)
        XCTAssertGreaterThan(UIPasteboard.general.changeCount, pasteboardChangeCount)

        let consumer = XCUIApplication(bundleIdentifier: "com.bigbear.AnkiInfoConsumer")
        XCTAssertTrue(consumer.wait(for: .runningForeground, timeout: 10), consumer.debugDescription)
        let pasteControl = consumer.buttons["infoConsumer.pasteControl"]
        XCTAssertTrue(pasteControl.waitForExistence(timeout: 10), consumer.debugDescription)
        XCTAssertTrue(pasteControl.isEnabled, consumer.debugDescription)
        activate(pasteControl)

        let pastedPayload = consumer.textViews["infoConsumer.pasteTarget"]
        XCTAssertTrue(pastedPayload.waitForExistence(timeout: 10), consumer.debugDescription)
        let payloadData = Data((pastedPayload.value as? String ?? "").utf8)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadData) as? [String: Any], consumer.debugDescription)
        XCTAssertEqual(Set(payload.keys), Set(["decks", "notetypes", "profile"]), consumer.debugDescription)
        XCTAssertTrue((payload["profile"] as? String)?.isEmpty == false, consumer.debugDescription)
        XCTAssertTrue((payload["decks"] as? [String])?.contains("Default") == true, consumer.debugDescription)
        XCTAssertTrue((payload["notetypes"] as? [String])?.contains("Basic") == true, consumer.debugDescription)
    }
#endif

    func testStudyRatingShortcutDoesNotFireInEditor() {
        addNote()
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        activate(identified("study.revealAnswer"))
        XCTAssertTrue(app.webViews.staticTexts["UI answer"].firstMatch.waitForExistence(timeout: 10))

        activate(identified("study.action.Editar"))
        button("Editar HTML")
        let frontField = app.textViews["field.source.Front"].firstMatch
        XCTAssertTrue(frontField.waitForExistence(timeout: 10), app.debugDescription)
        enter("3", into: frontField)
        XCTAssertTrue(frontField.exists, app.debugDescription)
        activate(identified("noteEditor.close"))

        XCTAssertTrue(app.webViews.staticTexts["UI answer"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(identified("study.rating.3").waitForExistence(timeout: 5), app.debugDescription)
    }

    func testPreferencesPersistence() {
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let toggle = identified("preferences.Modo minimalista")
        reveal(toggle)
        activate(toggle)
        activate(identified("preferences.save"))
#if os(iOS)
        let gamepadAction = identified("preferences.gamepad.buttonA")
        reveal(gamepadAction)
        activate(gamepadAction)
        menuButton("Mostrar resposta", swipeDown: true)
        let deadZone = identified("preferences.gamepad.deadZone")
        reveal(deadZone)
        let initialDeadZone = deadZone.value as? String ?? ""
        deadZone.adjust(toNormalizedSliderPosition: 0.7)
        let savedDeadZone = deadZone.value as? String ?? ""
        XCTAssertNotEqual(savedDeadZone, initialDeadZone, app.debugDescription)
        activate(identified("preferences.save"))
        let ankiWebSettings: [(String, Bool)] = [
            ("preferences.Sincronizar áudio e imagens", false),
            ("preferences.Sincronizar ao abrir e fechar o perfil", false),
            ("preferences.Sincronizar mídia a cada 15 minutos", false),
            ("preferences.Na próxima sincronização, escolher enviar ou baixar", true)
        ]
        for (identifier, enabled) in ankiWebSettings {
            let setting = identified(identifier)
            reveal(setting)
            let currentValue = (setting.value as? String) == "1"
            if currentValue != enabled { activate(setting) }
        }
#endif
        button("Salvar preferências")
        app.terminate()
        app.launch()
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let restored = identified("preferences.Modo minimalista")
        reveal(restored)
        XCTAssertEqual(restored.value as? String, "1")
#if os(iOS)
        let restoredGamepadAction = identified("preferences.gamepad.buttonA")
        reveal(restoredGamepadAction)
        XCTAssertTrue(restoredGamepadAction.label.contains("Mostrar resposta"), app.debugDescription)
        let restoredDeadZone = identified("preferences.gamepad.deadZone")
        reveal(restoredDeadZone)
        XCTAssertEqual(restoredDeadZone.value as? String, savedDeadZone, app.debugDescription)
        let restoredAnkiWebSettings: [(String, String)] = [
            ("preferences.Sincronizar áudio e imagens", "0"),
            ("preferences.Sincronizar ao abrir e fechar o perfil", "0"),
            ("preferences.Sincronizar mídia a cada 15 minutos", "0"),
            ("preferences.Na próxima sincronização, escolher enviar ou baixar", "1")
        ]
        for (identifier, expectedValue) in restoredAnkiWebSettings {
            let setting = identified(identifier)
            reveal(setting)
            XCTAssertEqual(setting.value as? String, expectedValue, app.debugDescription)
        }
#endif
    }

#if os(iOS)
    func testVirtualGamepadButtonARevealsStudyAnswer() {
        addNote(front: "UI gamepad question", back: "UI gamepad answer")
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let gamepadAction = identified("preferences.gamepad.buttonA")
        reveal(gamepadAction)
        activate(gamepadAction)
        menuButton("Mostrar resposta", swipeDown: true)
        button("Salvar preferências")

        app.terminate()
        app.launchEnvironment["ANKIOS_UI_TEST_VIRTUAL_GAMEPAD"] = "buttonA"
        app.launch()
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")

        XCTAssertTrue(app.webViews.staticTexts["UI gamepad question"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.webViews.staticTexts["UI gamepad answer"].waitForExistence(timeout: 15), app.debugDescription)
    }
#endif

    func testThemeAndReduceMotionPreferencesPersist() {
        navigate("Ferramentas")
        button("Preferências do AnkiOS")

        let theme = identified("preferences.Tema")
        reveal(theme)
        activate(theme)
        button("Escuro")

        let reduceMotion = identified("preferences.Reduzir movimento")
        reveal(reduceMotion)
        if (reduceMotion.value as? String) == "1" {
            activate(reduceMotion)
        }
        XCTAssertEqual(reduceMotion.value as? String, "0", app.debugDescription)
        button("Salvar preferências")

        app.terminate()
        app.launch()
        navigate("Ferramentas")
        button("Preferências do AnkiOS")

        let restoredTheme = identified("preferences.Tema")
        reveal(restoredTheme)
        XCTAssertTrue(app.staticTexts["Escuro"].exists, app.debugDescription)
        let restoredReduceMotion = identified("preferences.Reduzir movimento")
        reveal(restoredReduceMotion)
        XCTAssertEqual(restoredReduceMotion.value as? String, "0", app.debugDescription)
    }

    func testStudyReminderSettingsPersistAfterRelaunch() {
        navigate("Ferramentas")
        button("Preferências do AnkiOS")

        let reminder = identified("preferences.notifications.enabled")
        XCTAssertTrue(reminder.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(reminder.label.contains("Alertar quando houver cartões pendentes"), app.debugDescription)
        let reminderSwitch = reminder.children(matching: .switch).firstMatch
        setToggle(reminderSwitch.exists ? reminderSwitch : reminder, to: true)
        let reminderTime = identified("preferences.notifications.time")
        XCTAssertTrue(reminderTime.waitForExistence(timeout: 10), app.debugDescription)
        let savedTimeValue = reminderTime.value as? String
        activate(identified("preferences.save"))

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let appPrompt = app.alerts.firstMatch
        let springboardPrompt = springboard.alerts.firstMatch
        let notificationPrompt: XCUIElement
        if appPrompt.waitForExistence(timeout: 2) {
            notificationPrompt = appPrompt
        } else if springboardPrompt.waitForExistence(timeout: 10) {
            notificationPrompt = springboardPrompt
        } else {
            notificationPrompt = appPrompt
        }
        if notificationPrompt.exists {
            let allowNotifications = notificationPrompt.buttons.matching(
                NSPredicate(format: "label == %@ OR label == %@ OR label == %@", "Allow", "Permitir", "Permitir notificações")
            ).firstMatch
            XCTAssertTrue(allowNotifications.waitForExistence(timeout: 10), app.debugDescription)
            activate(allowNotifications)
        }
        XCTAssertTrue(identified("preferences.notifications.status").waitForExistence(timeout: 15), app.debugDescription)

        app.terminate()
        app.launch()
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let restoredReminder = identified("preferences.notifications.enabled")
        XCTAssertEqual("\(restoredReminder.value ?? "")", "1", app.debugDescription)
        let restoredTime = identified("preferences.notifications.time")
        XCTAssertTrue(restoredTime.exists, app.debugDescription)
        if let savedTimeValue { XCTAssertEqual(restoredTime.value as? String, savedTimeValue, app.debugDescription) }
        XCTAssertTrue(identified("preferences.notifications.status").waitForExistence(timeout: 10), app.debugDescription)

        let restoredReminderSwitch = restoredReminder.children(matching: .switch).firstMatch
        setToggle(restoredReminderSwitch.exists ? restoredReminderSwitch : restoredReminder, to: false)
        activate(identified("preferences.save"))
        app.terminate()
        app.launch()
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        XCTAssertEqual("\(identified("preferences.notifications.enabled").value ?? "")", "0", app.debugDescription)
        XCTAssertFalse(identified("preferences.notifications.status").exists, app.debugDescription)
    }

    func testLanguagePreferencePersistsAfterRelaunch() {
        #if os(iOS)
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        XCTAssertFalse(identified("preferences.language").exists, app.debugDescription)

        app.terminate()
        app.launch()
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        XCTAssertFalse(identified("preferences.language").exists, app.debugDescription)
        XCTAssertFalse(app.alerts["Idioma alterado"].exists, app.debugDescription)
        #else
        navigate("Ferramentas")
        button("Preferências do AnkiOS")

        let language = identified("preferences.language")
        reveal(language)
        if (language.value as? String) != "Português Brasileiro" {
            activate(language)
            let portugueseOption = app.buttons["Português Brasileiro"].firstMatch
            let collectionViews = app.collectionViews
            XCTAssertTrue(collectionViews.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
            let languageOptions = collectionViews.element(boundBy: collectionViews.count - 1)
            for _ in 0..<6 {
                if portugueseOption.exists && portugueseOption.isHittable { break }
                languageOptions.swipeUp()
            }
            activate(portugueseOption)
            XCTAssertTrue(app.alerts["Idioma alterado"].waitForExistence(timeout: 5), app.debugDescription)
            button("OK")
        }

        app.terminate()
        app.launch()
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        XCTAssertFalse(app.alerts["Idioma alterado"].exists, app.debugDescription)

        let restoredLanguage = identified("preferences.language")
        reveal(restoredLanguage)
        XCTAssertEqual(restoredLanguage.value as? String, "Português Brasileiro", app.debugDescription)
        #endif
    }

    #if os(iOS)
    func testCustomStudyCreatesLocalizedFilteredDeck() {
        addNote(front: "Custom study included question", back: "Custom study included answer", tags: "parityinclude")
        addNote(front: "Custom study excluded question", back: "Custom study excluded answer", tags: "parityexclude")
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        selectLanguage("English (United States)")

        app.terminate()
        app.launch()

        navigate("Decks")
        activate(app.buttons["deck.open.Default"])
        button("Custom Study")
        button("Study by card state or tag")
        let chooseTags = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Choose Tags")
        ).firstMatch
        activate(chooseTags)

        let requireOneTag = app.switches["Require one or more of these tags:"].firstMatch
        XCTAssertTrue(requireOneTag.waitForExistence(timeout: 10), app.debugDescription)
        activate(requireOneTag)
        activate(app.buttons["parityinclude"].firstMatch)
        let excludedTag = app.buttons.matching(NSPredicate(format: "label == %@", "parityexclude"))
        XCTAssertEqual(excludedTag.count, 2, app.debugDescription)
        activate(excludedTag.element(boundBy: 1))
        let acceptTags = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "OK")
        ).firstMatch
        activate(acceptTags)

        let sessionTitle = app.staticTexts["Custom Study Session"].firstMatch
        XCTAssertTrue(sessionTitle.waitForExistence(timeout: 15), app.debugDescription)
        activate(identified("deck.overview.close"))
        activate(identified("deck.overview.close"))
        let filteredNewCount = identified("deck.count.Custom Study Session.new")
        XCTAssertTrue(filteredNewCount.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(filteredNewCount.label, "1", app.debugDescription)
        XCTAssertEqual(identified("deck.count.Default.new").label, "1", app.debugDescription)
    }

    func testCustomStudyRebuildAndReturnsCards() throws {
        let package = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "custom-study", withExtension: "apkg"))
        app.open(package)
        let importAction = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Importar")
        ).firstMatch
        XCTAssertTrue(importAction.waitForExistence(timeout: 10), app.debugDescription)
        activate(importAction)
        if importAction.waitForExistence(timeout: 5) {
            activate(importAction)
        }
        finishTutorialIfPresented()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        button("OK")
        finishTutorialIfPresented()
        activate(app.buttons["deck.open.UI Custom"])
        XCTAssertTrue(app.buttons["Estudar agora"].waitForExistence(timeout: 10), app.debugDescription)
        let customStudy = identified("deck.overview.customStudy")
        reveal(customStudy)
        activate(customStudy)
        let cramMode = identified("customStudy.mode.cram")
        reveal(cramMode)
        activate(cramMode)
        activate(identified("customStudy.accept"))

        let requireOneTag = identified("customStudy.tags.requireOne")
        XCTAssertTrue(requireOneTag.waitForExistence(timeout: 10), app.debugDescription)
        if requireOneTag.value as? String != "1" {
            activate(requireOneTag)
        }
        let includeTag = identified("customStudy.tag.include.parityinclude")
        XCTAssertTrue(includeTag.waitForExistence(timeout: 10), app.debugDescription)
        activate(includeTag)
        activate(identified("customStudy.tags.accept"))

        let sessionTitle = app.staticTexts["Sessão de Estudo Personalizado"].firstMatch
        XCTAssertTrue(sessionTitle.waitForExistence(timeout: 15), app.debugDescription)
        let overviewCloses = app.buttons.matching(identifier: "deck.overview.close")
        XCTAssertEqual(overviewCloses.count, 2, app.debugDescription)
        for index in stride(from: overviewCloses.count - 1, through: 0, by: -1) {
            let closeOverview = overviewCloses.element(boundBy: index)
            let closeIsHittable = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isHittable == true"),
                object: closeOverview
            )
            XCTAssertEqual(XCTWaiter.wait(for: [closeIsHittable], timeout: 10), .completed, app.debugDescription)
            activate(closeOverview)
        }
        let customDeckRow = app.buttons["deck.open.UI Custom"].firstMatch
        XCTAssertTrue(customDeckRow.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(customDeckRow.isHittable, app.debugDescription)
        let filteredNewCount = identified("deck.count.Sessão de Estudo Personalizado.new")
        XCTAssertTrue(filteredNewCount.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(filteredNewCount.label, "1", app.debugDescription)
        XCTAssertEqual(identified("deck.count.UI Custom.new").label, "0", app.debugDescription)

        addNote(front: "New custom match", back: "New custom answer", tags: "parityinclude", deckName: "UI Custom")
        navigate("Baralhos")
        XCTAssertEqual(filteredNewCount.label, "1", app.debugDescription)
        XCTAssertEqual(identified("deck.count.UI Custom.new").label, "1", app.debugDescription)

        activate(app.buttons["deck.open.Sessão de Estudo Personalizado"])
        button("Estudar agora")
        let studyTools = identified("study.topBar.action")
        activate(studyTools)
        activate(revealStudyToolAction("rebuildFilteredDeck"))
        XCTAssertTrue(identified("study.cardArea").waitForExistence(timeout: 10), app.debugDescription)
        activate(revealStudyToolAction("emptyFilteredDeck"))
        activate(revealStudyToolAction("decks"))
        XCTAssertEqual(filteredNewCount.label, "0", app.debugDescription)
        XCTAssertEqual(identified("deck.count.UI Custom.new").label, "2", app.debugDescription)

        let filteredDeckRow = app.buttons["deck.open.Sessão de Estudo Personalizado"].firstMatch
        waitUntilHittable(filteredDeckRow)
        activate(filteredDeckRow)
        let rebuild = identified("filteredDeck.rebuild")
        XCTAssertTrue(rebuild.waitForExistence(timeout: 10), app.debugDescription)
        activate(rebuild)
        let rebuiltOverviewClose = identified("deck.overview.close")
        waitUntilHittable(rebuiltOverviewClose)
        activate(rebuiltOverviewClose)
        XCTAssertEqual(filteredNewCount.label, "2", app.debugDescription)
        XCTAssertEqual(identified("deck.count.UI Custom.new").label, "0", app.debugDescription)

        activate(app.buttons["deck.open.Sessão de Estudo Personalizado"])
        let empty = identified("filteredDeck.empty")
        XCTAssertTrue(empty.waitForExistence(timeout: 10), app.debugDescription)
        activate(empty)
        let emptiedOverviewClose = identified("deck.overview.close")
        waitUntilHittable(emptiedOverviewClose)
        activate(emptiedOverviewClose)
        XCTAssertEqual(identified("deck.count.Sessão de Estudo Personalizado.new").label, "0", app.debugDescription)
        XCTAssertEqual(identified("deck.count.UI Custom.new").label, "2", app.debugDescription)
    }

    func testCustomStudyLabelsLocalizeInEnglish() {
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        selectLanguage("English (United States)")

        app.terminate()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Decks"].waitForExistence(timeout: 20), app.debugDescription)
        navigate("Browse")
        XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["Buried"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["Marked"].exists, app.debugDescription)
        navigate("Decks")
        activate(app.buttons["deck.open.Default"])
        button("Custom Study")
        XCTAssertTrue(app.buttons["Increase today's new card limit"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Increase today's new card limit by"].exists, app.debugDescription)
        button("Study by card state or tag")
        XCTAssertTrue(app.buttons["Choose Tags"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["New cards only"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["Due cards only"].exists, app.debugDescription)
        activate(identified("customStudy.mode.ahead"))
        let amountUnit = identified("customStudy.amount.unit")
        XCTAssertEqual(amountUnit.label, "day", app.debugDescription)
        incrementStepper(identified("customStudy.amount.stepper"))
        XCTAssertEqual(amountUnit.label, "days", app.debugDescription)
        button("Cancel")

        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(ru-RU)", "-AppleLocale", "ru_RU"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons.element(boundBy: 0).waitForExistence(timeout: 20), app.debugDescription)
        activate(app.buttons["deck.open.Default"])
        activate(identified("deck.overview.customStudy"))
        activate(identified("customStudy.mode.ahead"))
        let russianAmountUnit = identified("customStudy.amount.unit")
        XCTAssertEqual(russianAmountUnit.label, "день", app.debugDescription)
        incrementStepper(identified("customStudy.amount.stepper"))
        XCTAssertEqual(russianAmountUnit.label, "дня", app.debugDescription)
        incrementStepper(identified("customStudy.amount.stepper"), times: 2)
        XCTAssertEqual(russianAmountUnit.label, "дня", app.debugDescription)
        incrementStepper(identified("customStudy.amount.stepper"))
        XCTAssertEqual(russianAmountUnit.label, "дней", app.debugDescription)
        activate(identified("customStudy.cancel"))
    }

    func testLanguagePreferenceLocalizesNavigationAndPersistsAfterRelaunch() {
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        XCTAssertFalse(identified("preferences.language").exists, app.debugDescription)
        selectLanguage("English (United States)")

        app.terminate()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Decks"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.tabBars.buttons["Add"].exists, app.debugDescription)
        XCTAssertTrue(app.tabBars.buttons["Statistics"].exists, app.debugDescription)
        XCTAssertTrue(app.tabBars.buttons["Tools"].exists, app.debugDescription)

        navigate("Tools")
        XCTAssertTrue(app.buttons["Sign in"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["Check Database"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["Manage Note Types"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["Add Note"].exists, app.debugDescription)
        button("Preferências do AnkiOS")
        XCTAssertEqual(identified("preferences.Modo minimalista").label, "Minimalist mode", app.debugDescription)
        XCTAssertFalse(identified("preferences.language").exists, app.debugDescription)
        selectLanguage("Português Brasileiro")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Baralhos"].waitForExistence(timeout: 20), app.debugDescription)
    }

    func testPreferencesFSRSSettingPersistsAfterRelaunch() {
        navigate("Ferramentas")
        button("Preferências do AnkiOS")

        let fsrs = identified("settings.scheduler.fsrs")
        XCTAssertTrue(fsrs.waitForExistence(timeout: 10), app.debugDescription)
        let wasEnabled = (fsrs.value as? String) == "1"
        activate(fsrs)

        app.terminate()
        app.launch()
        navigate("Ferramentas")
        button("Preferências do AnkiOS")

        let restoredFSRS = identified("settings.scheduler.fsrs")
        XCTAssertTrue(restoredFSRS.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual((restoredFSRS.value as? String) == "1", !wasEnabled, app.debugDescription)
        activate(restoredFSRS)
    }

    func testDeckFSRSRetentionOverridePersistsAfterRelaunch() {
        createDeck("UI FSRS")
        navigate("Ferramentas")
        button("Preferências do AnkiOS")

        let fsrs = identified("settings.scheduler.fsrs")
        XCTAssertTrue(fsrs.waitForExistence(timeout: 10), app.debugDescription)
        let wasEnabled = (fsrs.value as? String) == "1"
        if !wasEnabled { activate(fsrs) }

        app.terminate()
        app.launch()
        navigate("Baralhos")
        activate(app.buttons["deck.options.UI FSRS"])

        XCTAssertTrue(app.staticTexts["Retenção padrão do preset"].waitForExistence(timeout: 10), app.debugDescription)
        let override = app.switches["Retenção específica deste baralho"].firstMatch
        XCTAssertTrue(override.waitForExistence(timeout: 10), app.debugDescription)
        activate(override)
        let retention = identified("deck.options.number.Retenção desejada")
        XCTAssertTrue(retention.waitForExistence(timeout: 10), app.debugDescription)
        activate(retention)
        let originalRetention = retention.value as? String ?? ""
        retention.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: originalRetention.count))
        retention.typeText("0,83")
        if app.buttons["Ocultar teclado"].exists { button("Ocultar teclado") }
        button("Salvar")

        app.terminate()
        app.launch()
        navigate("Baralhos")
        activate(app.buttons["deck.options.UI FSRS"])

        let restoredOverride = app.switches["Retenção específica deste baralho"].firstMatch
        XCTAssertTrue(restoredOverride.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(restoredOverride.value as? String, "1", app.debugDescription)
        let restoredRetention = identified("deck.options.number.Retenção desejada")
        XCTAssertTrue(restoredRetention.exists, app.debugDescription)
        let persistedRetention = (restoredRetention.value as? String ?? "").replacingOccurrences(of: ",", with: ".")
        let parsedRetention = Double(persistedRetention)
        XCTAssertNotNil(parsedRetention, app.debugDescription)
        XCTAssertEqual(parsedRetention ?? -1, 0.83, accuracy: 0.001, app.debugDescription)
        activate(restoredOverride)
        button("Salvar")

        if !wasEnabled {
            navigate("Ferramentas")
            button("Preferências do AnkiOS")
            let restoredFSRS = identified("settings.scheduler.fsrs")
            XCTAssertTrue(restoredFSRS.waitForExistence(timeout: 10), app.debugDescription)
            activate(restoredFSRS)
        }
    }

    func testDeckFSRSPresetRetentionPersistsAfterRelaunch() {
        navigate("Ferramentas")
        button("Preferências do AnkiOS")

        let fsrs = identified("settings.scheduler.fsrs")
        XCTAssertTrue(fsrs.waitForExistence(timeout: 10), app.debugDescription)
        let wasEnabled = (fsrs.value as? String) == "1"
        if !wasEnabled { activate(fsrs) }

        app.terminate()
        app.launch()
        navigate("Baralhos")
        activate(app.buttons["deck.options.Default"])

        let retention = identified("deck.options.number.Retenção padrão do preset")
        reveal(retention)
        XCTAssertTrue(retention.waitForExistence(timeout: 10), app.debugDescription)
        let originalText = retention.value as? String ?? "0,9"
        let originalValue = Double(originalText.replacingOccurrences(of: ",", with: ".")) ?? 0.9
        activate(retention)
        retention.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: originalText.count))
        retention.typeText("0,85")
        if app.buttons["Ocultar teclado"].exists { button("Ocultar teclado") }
        button("Salvar")

        app.terminate()
        app.launch()
        navigate("Baralhos")
        activate(app.buttons["deck.options.Default"])
        let restoredRetention = identified("deck.options.number.Retenção padrão do preset")
        reveal(restoredRetention)
        XCTAssertTrue(restoredRetention.waitForExistence(timeout: 10), app.debugDescription)
        let persistedText = restoredRetention.value as? String ?? ""
        let persistedValue = Double(persistedText.replacingOccurrences(of: ",", with: "."))
        XCTAssertNotNil(persistedValue, app.debugDescription)
        XCTAssertEqual(persistedValue ?? -1, 0.85, accuracy: 0.001, app.debugDescription)

        activate(restoredRetention)
        restoredRetention.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: persistedText.count))
        restoredRetention.typeText(String(format: "%.2f", originalValue).replacingOccurrences(of: ".", with: ","))
        if app.buttons["Ocultar teclado"].exists { button("Ocultar teclado") }
        button("Salvar")

        if !wasEnabled {
            navigate("Ferramentas")
            button("Preferências do AnkiOS")
            let restoredFSRS = identified("settings.scheduler.fsrs")
            XCTAssertTrue(restoredFSRS.waitForExistence(timeout: 10), app.debugDescription)
            activate(restoredFSRS)
        }
    }
    #endif

    #if os(macOS)
    func testDeckFSRSRetentionOverridePersistsAfterRelaunchOnMacOS() {
        navigate("Ferramentas")
        button("Preferências do AnkiOS")

        let fsrs = identified("settings.scheduler.fsrs")
        XCTAssertTrue(fsrs.waitForExistence(timeout: 10), app.debugDescription)
        let wasEnabled = String(describing: fsrs.value ?? "") == "1"
        if !wasEnabled { activate(fsrs) }

        app.terminate()
        app.launch()
        navigate("Baralhos")
        activate(app.buttons["deck.options.Default"])

        let override = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Retenção específica deste baralho")
        ).firstMatch
        XCTAssertTrue(override.waitForExistence(timeout: 10), app.debugDescription)
        if String(describing: override.value ?? "") != "1" { activate(override) }
        let retention = identified("deck.options.number.Retenção desejada")
        XCTAssertTrue(retention.waitForExistence(timeout: 10), app.debugDescription)
        let originalRetention = String(describing: retention.value ?? "")
        activate(retention)
        retention.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: originalRetention.count))
        retention.typeText("0,83")
        button("Salvar")

        app.terminate()
        app.launch()
        navigate("Baralhos")
        activate(app.buttons["deck.options.Default"])

        let restoredOverride = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Retenção específica deste baralho")
        ).firstMatch
        XCTAssertTrue(restoredOverride.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(String(describing: restoredOverride.value ?? ""), "1", app.debugDescription)
        let restoredRetention = identified("deck.options.number.Retenção desejada")
        XCTAssertTrue(restoredRetention.waitForExistence(timeout: 10), app.debugDescription)
        let persistedRetention = String(describing: restoredRetention.value ?? "").replacingOccurrences(of: ",", with: ".")
        XCTAssertEqual(Double(persistedRetention) ?? -1, 0.83, accuracy: 0.001, app.debugDescription)

        activate(restoredOverride)
        button("Salvar")
        if !wasEnabled {
            navigate("Ferramentas")
            button("Preferências do AnkiOS")
            let restoredFSRS = identified("settings.scheduler.fsrs")
            XCTAssertTrue(restoredFSRS.waitForExistence(timeout: 10), app.debugDescription)
            activate(restoredFSRS)
        }
    }
    #endif

    func testCollectionMaintenance() {
        navigate("Adicionar")
        if !app.textViews["field.source.Front"].firstMatch.exists { button("add.source") }
        enter("UI maintenance note", into: app.textViews["field.source.Front"].firstMatch)
        button("add.submit")
        XCTAssertTrue(app.staticTexts["Nota adicionada."].waitForExistence(timeout: 10), app.debugDescription)
        finishTutorialIfPresented()
        navigate("Ferramentas")
        let databaseCheck = identified("settings.database.check")
        XCTAssertTrue(databaseCheck.waitForExistence(timeout: 15), app.debugDescription)
        activate(databaseCheck)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 60))
        #if os(iOS)
        XCTAssertTrue(app.alerts.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Banco de dados verificado. Nenhum problema encontrado.")
        ).firstMatch.exists, app.debugDescription)
        #else
        XCTAssertTrue(app.alerts.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Coleção verificada e otimizada: 1 notas, 1 cartões")
        ).firstMatch.exists, app.debugDescription)
        #endif
        button("OK")
        activate(identified("settings.backup.create"))
        XCTAssertTrue(app.alerts.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Backup criado:")
        ).firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        button("OK")
        activate(identified("settings.media.check"))
        XCTAssertTrue(app.buttons["Concluído"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["0 arquivos, 0 não usados e 0 ausentes."].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Nenhum arquivo ausente."].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Nenhum arquivo não usado."].exists, app.debugDescription)
        button("Concluído")
    }

    func testAutomaticCollectionBackupCanBeRestoredFromTools() {
        navigate("Ferramentas")
        activate(identified("settings.backup.create"))
        XCTAssertTrue(app.alerts.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Backup criado:")
        ).firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        button("OK")

        createDeck("UI backup later")
        navigate("Ferramentas")
        let restore = identified("settings.backup.restore")
        XCTAssertTrue(restore.waitForExistence(timeout: 15), app.debugDescription)
        activate(restore)
        let replace = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Substituir")).firstMatch
        XCTAssertTrue(replace.waitForExistence(timeout: 15), app.debugDescription)
        activate(replace)
        XCTAssertTrue(app.alerts.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Coleção restaurada do .colpkg")
        ).firstMatch.waitForExistence(timeout: 60), app.debugDescription)
        button("OK")

        navigate("Baralhos")
        XCTAssertTrue(app.buttons["deck.open.Default"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["deck.open.UI backup later"].exists, app.debugDescription)
    }

    func testExportFullCollectionPackageFromTools() {
        addNote(front: "UI collection export", back: "UI collection package")
        navigate("Ferramentas")
        let export = identified("settings.export.colpkg")
        reveal(export)
        activate(export)
        let shareSheet = identified("settings.export.share-sheet")
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 60), app.debugDescription)
    }

    func testExportSelectedDeckPackageFromTools() {
        let deckName = "UI Export Parent"
        let childDeckName = "\(deckName)::Child"
        let unrelatedDeckName = "UI Export Unrelated"
        createDeck(deckName)
        createDeck(childDeckName)
        createDeck(unrelatedDeckName)
        addNote(front: "UI deck export parent", back: "UI parent package", deckName: deckName)
        addNote(front: "UI deck export child", back: "UI child package", deckName: childDeckName)
        addNote(front: "UI deck export unrelated", back: "UI unrelated package", deckName: unrelatedDeckName)
        navigate("Ferramentas")
        let export = identified("settings.export.apkg.deck")
        XCTAssertTrue(export.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(export.isEnabled, app.debugDescription)

        let deckChoice = identified("settings.export.deck")
        reveal(deckChoice)
        activate(deckChoice)
        activate(identified("settings.export.deck.choice.\(deckName)"))
        let selectedDeck = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS[c] %@", deckName),
            object: deckChoice
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selectedDeck], timeout: 10), .completed, app.debugDescription)
        XCTAssertTrue(export.isEnabled, app.debugDescription)
        reveal(export)
        activate(export)
        XCTAssertTrue(identified("settings.export.share-sheet").waitForExistence(timeout: 60), app.debugDescription)
    }

    func testExportFullCollectionApkgFromTools() {
        addNote(front: "UI collection APKG", back: "UI full collection package")
        navigate("Ferramentas")
        let export = identified("settings.export.apkg.collection")
        reveal(export)
        activate(export)
        XCTAssertTrue(identified("settings.export.share-sheet").waitForExistence(timeout: 60), app.debugDescription)
    }

    func testApkgExportOptionsPersistAfterRelaunch() {
        let options = [
            "settings.export.option.scheduling",
            "settings.export.option.deck-presets",
            "settings.export.option.media"
        ]
        navigate("Ferramentas")
        var originalValues: [String: String] = [:]
        for identifier in options {
            let option = identified(identifier)
            XCTAssertTrue(option.waitForExistence(timeout: 10), app.debugDescription)
            let originalValue = option.value as? String ?? "0"
            originalValues[identifier] = originalValue
            activate(option)
        }

        app.terminate()
        app.launch()
        navigate("Ferramentas")

        for identifier in options {
            let option = identified(identifier)
            XCTAssertTrue(option.waitForExistence(timeout: 10), app.debugDescription)
            let originalValue = originalValues[identifier] ?? "0"
            XCTAssertNotEqual(option.value as? String, originalValue, app.debugDescription)
            activate(option)
            XCTAssertEqual(option.value as? String, originalValue, app.debugDescription)
        }
    }

    func testRestoreCollectionPackageCanBeCancelledAndReplacesCollection() throws {
        addNote(front: "UI before restore", back: "UI original collection")
        let package = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "restore", withExtension: "colpkg"))

        app.open(package)
        let replace = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Substituir")).firstMatch
        XCTAssertTrue(replace.waitForExistence(timeout: 20), app.debugDescription)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        navigate("Painel")
        search("UI before restore")
        XCTAssertTrue(app.staticTexts["UI before restore"].waitForExistence(timeout: 10), app.debugDescription)

        app.open(package)
        let confirm = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Substituir")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), app.debugDescription)
        activate(confirm)
        XCTAssertTrue(app.alerts.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Coleção restaurada do .colpkg")
        ).firstMatch.waitForExistence(timeout: 60), app.debugDescription)
        button("OK")

        navigate("Baralhos")
        XCTAssertTrue(app.buttons["deck.open.UI Restore"].waitForExistence(timeout: 20), app.debugDescription)
        navigate("Painel")
        search("UI restored collection")
        XCTAssertTrue(app.staticTexts["UI restored collection"].waitForExistence(timeout: 10), app.debugDescription)
        search("UI before restore")
        XCTAssertTrue(app.staticTexts["Nenhum cartão"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testNoteTypesAndTemplates() {
        button("Mais ações dos baralhos")
        activate(identified("decks.noteTypes"))
        activate(identified("notetypes.action.Adicionar Basic (e invertido)"))
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "Tipos de nota"
        tree.lifetime = .keepAlways
        add(tree)
        let reversed = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Basic (and reversed)")).firstMatch
        XCTAssertTrue(reversed.waitForExistence(timeout: 10))
        activate(reversed)
        let addField = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Adicionar campo")).firstMatch
        activate(addField)
        XCTAssertTrue(app.textFields.containing(NSPredicate(format: "value == %@", "Campo 3")).firstMatch.exists)
        activate(identified("notetype.editor.save"))
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "3 campos · 2 templates")).firstMatch.waitForExistence(timeout: 10))
    }

    func testNoteTypeCSSAndPreviewPersist() {
        func previewText(_ text: String) -> XCUIElement {
            app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }
        func revealTemplateFieldAboveCurrentPosition(_ element: XCUIElement) {
            let scroll = app.scrollViews.firstMatch
            XCTAssertTrue(scroll.waitForExistence(timeout: 5), app.debugDescription)
            for _ in 0..<6 {
                let navigationBottom = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : 0
                if element.exists && element.isHittable
                    && element.frame.minY >= navigationBottom
                    && element.frame.maxY <= app.frame.maxY - 100 { return }
                scroll.swipeDown()
            }
            XCTAssertTrue(element.isHittable, app.debugDescription)
        }
        func placeCaretAtEnd(_ element: XCUIElement) {
            let textLength = (element.value as? String ?? "").count
            let offset = min(max((Double(textLength) * 7.6 + 12) / element.frame.width, 0.12), 0.86)
            element.coordinate(withNormalizedOffset: CGVector(dx: offset, dy: 0.5)).tap()
            XCTAssertTrue(app.buttons["Ocultar teclado"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        }

        button("Mais ações dos baralhos")
        activate(identified("decks.noteTypes"))
        let basic = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Basic,")).firstMatch
        XCTAssertTrue(basic.waitForExistence(timeout: 10), app.debugDescription)
        activate(basic)

        let css = identified("notetype.editor.css")
        XCTAssertTrue(css.waitForExistence(timeout: 10), app.debugDescription)
        enter(".card { color: rgb(255, 0, 0); }", into: css)

        let questionTemplate = identified("notetype.template.Frente (qfmt)")
        XCTAssertTrue(questionTemplate.waitForExistence(timeout: 10), app.debugDescription)
        revealTemplateFieldAboveCurrentPosition(questionTemplate)
        placeCaretAtEnd(questionTemplate)
        type("<strong>Question marker</strong>", into: questionTemplate)
        XCTAssertTrue(previewText("Question marker").waitForExistence(timeout: 10), app.debugDescription)

        let answerTemplate = identified("notetype.template.Verso (afmt)")
        XCTAssertTrue(answerTemplate.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(answerTemplate.isHittable, app.debugDescription)
        placeCaretAtEnd(answerTemplate)
        type("<strong>Answer marker</strong>", into: answerTemplate)

        reveal(app.webViews.firstMatch)
        activate(app.buttons["Verso"].firstMatch)
        XCTAssertTrue(previewText("Sample Back").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(previewText("Question marker").exists, app.debugDescription)
        XCTAssertTrue(previewText("Answer marker").waitForExistence(timeout: 10), app.debugDescription)
        activate(app.buttons["Frente"].firstMatch)
        XCTAssertTrue(previewText("Sample Front").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(previewText("Question marker").exists, app.debugDescription)
        activate(identified("notetype.editor.save"))

        let savedBasic = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Basic,")).firstMatch
        XCTAssertTrue(savedBasic.waitForExistence(timeout: 10), app.debugDescription)
        activate(savedBasic)
        let savedCSS = identified("notetype.editor.css")
        XCTAssertTrue(savedCSS.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue((savedCSS.value as? String)?.contains(".card { color: rgb(255, 0, 0); }") == true, app.debugDescription)
        let savedQuestionTemplate = identified("notetype.template.Frente (qfmt)")
        XCTAssertTrue((savedQuestionTemplate.value as? String)?.contains("Question marker") == true, app.debugDescription)
        let savedAnswerTemplate = identified("notetype.template.Verso (afmt)")
        XCTAssertTrue((savedAnswerTemplate.value as? String)?.contains("Answer marker") == true, app.debugDescription)
        reveal(app.webViews.firstMatch)
        activate(app.buttons["Verso"].firstMatch)
        XCTAssertTrue(previewText("Question marker").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(previewText("Answer marker").waitForExistence(timeout: 10), app.debugDescription)
        activate(app.buttons["Frente"].firstMatch)
        XCTAssertTrue(previewText("Question marker").waitForExistence(timeout: 10), app.debugDescription)
        activate(identified("notetype.editor.cancel"))
    }

    func testNoteTypeFieldsCanBePinnedAndReordered() {
        button("Mais ações dos baralhos")
        activate(identified("decks.noteTypes"))
        let basic = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Basic,")).firstMatch
        XCTAssertTrue(basic.waitForExistence(timeout: 10), app.debugDescription)
        activate(basic)

        let backSticky = identified("notetype.field.sticky.1")
        XCTAssertTrue(backSticky.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(backSticky.value as? String, "0", app.debugDescription)
        activate(backSticky)
        XCTAssertEqual(backSticky.value as? String, "1", app.debugDescription)
        activate(identified("notetype.field.moveUp.1"))
        activate(identified("notetype.editor.save"))

        let savedBasic = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Basic,")).firstMatch
        XCTAssertTrue(savedBasic.waitForExistence(timeout: 10), app.debugDescription)
        activate(savedBasic)
        XCTAssertEqual(identified("notetype.field.name.0").value as? String, "Back", app.debugDescription)
        XCTAssertEqual(identified("notetype.field.sticky.0").value as? String, "1", app.debugDescription)
        activate(identified("notetype.editor.cancel"))
    }

    #if os(iOS)
    func testStickyFieldCarriesIntoNextAddedNote() {
        button("Mais ações dos baralhos")
        activate(identified("decks.noteTypes"))
        let basic = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Basic,")).firstMatch
        XCTAssertTrue(basic.waitForExistence(timeout: 10), app.debugDescription)
        activate(basic)

        let backSticky = identified("notetype.field.sticky.1")
        XCTAssertTrue(backSticky.waitForExistence(timeout: 10), app.debugDescription)
        if backSticky.value as? String != "1" { activate(backSticky) }
        XCTAssertEqual(backSticky.value as? String, "1", app.debugDescription)
        activate(identified("notetype.editor.save"))

        let savedBasic = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Basic,")).firstMatch
        XCTAssertTrue(savedBasic.waitForExistence(timeout: 10), app.debugDescription)
        activate(savedBasic)
        XCTAssertEqual(identified("notetype.field.sticky.1").value as? String, "1", app.debugDescription)
        activate(identified("notetype.editor.cancel"))

        navigate("Adicionar")
        if !app.textViews["field.source.Front"].firstMatch.exists { button("add.source") }
        let front = app.textViews["field.source.Front"].firstMatch
        enter("UI stick 1", into: front)
        let back = app.textViews["field.source.Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), app.debugDescription)
        reveal(back)
        back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        type("UI pinned", into: back)
        button("add.submit")
        XCTAssertTrue(app.staticTexts["Nota adicionada."].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(back.value as? String, "UI pinned", app.debugDescription)
        XCTAssertEqual(front.value as? String, "", app.debugDescription)
        XCTAssertTrue(app.buttons["UI stick 1"].waitForExistence(timeout: 10), app.debugDescription)
    }
    #endif

    func testProfileIsolationAndPersistence() {
        addNote()
        navigate("Ferramentas")
        button("Perfis")
        button("Novo perfil…")
        enter("UI Second", into: app.alerts.textFields["Nome"].firstMatch)
        button("Criar")
        XCTAssertTrue(app.staticTexts["UI Second"].firstMatch.waitForExistence(timeout: 15))
#if os(iOS)
        activate(app.navigationBars.buttons.element(boundBy: 0))
        button("Preferências do AnkiOS")
        let secondProfileGamepadAction = identified("preferences.gamepad.buttonA")
        reveal(secondProfileGamepadAction)
        activate(secondProfileGamepadAction)
        menuButton("Mostrar resposta", swipeDown: true)
        activate(identified("preferences.save"))
        activate(app.navigationBars.buttons.element(boundBy: 0))
        button("Perfis")
#endif
        navigate("Painel")
        search("UI question")
        XCTAssertTrue(app.staticTexts["Nenhum cartão"].waitForExistence(timeout: 10))
        navigate("Ferramentas")
        button("User 1")
#if os(iOS)
        activate(app.navigationBars.buttons.element(boundBy: 0))
        button("Preferências do AnkiOS")
        let defaultProfileGamepadAction = identified("preferences.gamepad.buttonA")
        reveal(defaultProfileGamepadAction)
        XCTAssertTrue(defaultProfileGamepadAction.label.contains("Nenhuma ação"), app.debugDescription)
        activate(app.navigationBars.buttons.element(boundBy: 0))
        button("Perfis")
        button("UI Second")
        activate(app.navigationBars.buttons.element(boundBy: 0))
        button("Preferências do AnkiOS")
        let restoredSecondProfileGamepadAction = identified("preferences.gamepad.buttonA")
        reveal(restoredSecondProfileGamepadAction)
        XCTAssertTrue(restoredSecondProfileGamepadAction.label.contains("Mostrar resposta"), app.debugDescription)
        activate(app.navigationBars.buttons.element(boundBy: 0))
        button("Perfis")
        button("User 1")
#endif
        navigate("Painel")
        search("UI question")
        XCTAssertTrue(app.staticTexts["UI question"].firstMatch.waitForExistence(timeout: 10))
    }

    func testStatisticsPeriodsAndScope() {
        addNote()
        navigate("Estatísticas")
        for (period, days) in [("3 meses", 90), ("1 ano", 365), ("Tudo", 0), ("1 mês", 31)] {
            button(period)
            XCTAssertTrue(identified("stats.period.\(days)").isSelected, app.debugDescription)
            XCTAssertTrue(app.staticTexts["Hoje"].exists)
        }
        XCTAssertTrue(identified("stats.calendar.day.0").exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Calendário"].exists)
        let retention = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Retenção verdadeira")
        ).firstMatch
        reveal(retention)
        XCTAssertTrue(retention.exists)
    }

    #if os(iOS)
    func testStatisticsScopeFiltersCollectionAndDeck() {
        addNote(front: "UI Stats Default", back: "UI Stats Default answer")
        let deckName = "UI Statistics Deck Scope With A Very Long Name To Verify Multiline Layout"
        createDeck(deckName)
        navigate("Adicionar")
        activate(identified("add.deck"))
        button(deckName)
        enterSourceField("UI Stats Custom", named: "Front")
        enterSourceField("UI Stats Custom answer", named: "Back")
        button("add.submit")
        XCTAssertTrue(app.staticTexts["Nota adicionada."].waitForExistence(timeout: 10), app.debugDescription)

        navigate("Estatísticas")
        let deckFilter = identified("stats.deckFilter")
        XCTAssertTrue(deckFilter.waitForExistence(timeout: 10), app.debugDescription)
        let notesCount = identified("stats.collection.notes")
        let cardsCount = identified("stats.collection.cards")
        let waitForCount: (XCUIElement, String) -> Void = { element, count in
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", count, count),
                object: element
            )
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed, self.app.debugDescription)
        }

        XCTAssertTrue(deckFilter.label.contains(deckName), app.debugDescription)
        XCTAssertGreaterThan(deckFilter.frame.height, 60, app.debugDescription)
        waitForCount(notesCount, "Notas, 1")
        waitForCount(cardsCount, "Cartões, 1")
        activate(deckFilter)
        button("Toda a coleção")
        waitForCount(notesCount, "Notas, 2")
        waitForCount(cardsCount, "Cartões, 2")
        activate(deckFilter)
        button(deckName)
        waitForCount(notesCount, "Notas, 1")
        waitForCount(cardsCount, "Cartões, 1")
    }

    func testStatisticsCardStatesAndDistributionMatchCollection() {
        addNote(front: "UI Stats Distribution", back: "UI Stats Distribution answer")
        navigate("Estatísticas")

        let expectedValues = [
            "stats.states.new": "Novos, 1",
            "stats.states.learning": "Aprendizagem, 0",
            "stats.states.review": "Revisão, 0",
            "stats.states.suspended": "Suspensos, 0",
            "stats.states.buried": "Ocultos, 0",
            "stats.distribution.mature": "Maduros, 0 · 0%",
            "stats.distribution.youngAndLearning": "Jovens e aprendizagem, 0 · 0%",
            "stats.distribution.unseen": "Não vistos, 1 · 100%",
            "stats.distribution.suspendedAndBuried": "Suspensos e ocultos, 0 · 0%",
            "stats.distribution.total": "Total de cartões, 1"
        ]

        for (identifier, expectedValue) in expectedValues {
            let element = identified(identifier)
            XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription)
            reveal(element)
            XCTAssertTrue(element.label.contains(expectedValue), "\(identifier): \(element.label)\n\(app.debugDescription)")
        }
    }

    func testStatisticsAnswerBreakdownReflectsReviewButton() {
        addNote(front: "UI Stats Button", back: "UI Stats Button answer")
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        button("Mostrar resposta")
        button("study.rating.4")
        XCTAssertTrue(app.staticTexts["Parabéns! Você terminou este baralho por enquanto."]
            .waitForExistence(timeout: 15), app.debugDescription)
        activate(identified("study.close"))
        activate(identified("deck.overview.close"))

        navigate("Estatísticas")
        let learningAnswers = identified("stats.answerBreakdown.value.Aprender")
        XCTAssertTrue(learningAnswers.waitForExistence(timeout: 10), app.debugDescription)
        reveal(learningAnswers)
        let value = learningAnswers.label + " " + (learningAnswers.value as? String ?? "")
        XCTAssertTrue(value.contains("0 · 0 · 0 · 1 · 100.0% corretas"), app.debugDescription)
    }

    func testStatisticsCalendarStartWeekdayPersistsAfterRelaunch() {
        navigate("Estatísticas")
        let calendarTitle = app.staticTexts["Calendário"].firstMatch
        reveal(calendarTitle)

        let weekdayButtons = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Começar a semana em")
        )
        XCTAssertEqual(weekdayButtons.count, 7, app.debugDescription)
        let originalStartDay = weekdayButtons.element(boundBy: 0).label
        let nextStartDay = weekdayButtons.element(boundBy: 1).label
        activate(weekdayButtons.element(boundBy: 1))

        let firstWeekday = weekdayButtons.element(boundBy: 0)
        let changedStartExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", nextStartDay),
            object: firstWeekday
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changedStartExpectation], timeout: 10), .completed, app.debugDescription)

        app.terminate()
        app.launch()
        navigate("Estatísticas")
        reveal(app.staticTexts["Calendário"].firstMatch)
        let restoredStartDay = weekdayButtons.element(boundBy: 0)
        let restoredExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", nextStartDay),
            object: restoredStartDay
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restoredExpectation], timeout: 10), .completed, app.debugDescription)

        let restoreOriginalDay = app.buttons.matching(
            NSPredicate(format: "label == %@", originalStartDay)
        ).firstMatch
        activate(restoreOriginalDay)
        let restoredOriginalExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", originalStartDay),
            object: weekdayButtons.element(boundBy: 0)
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restoredOriginalExpectation], timeout: 10), .completed, app.debugDescription)
    }
    #endif

    func testStatisticsShowsZeroBeforeAnyReviewAcrossPeriods() {
        addNote()
        navigate("Estatísticas")

        let todayCount = identified("stats.today.count")
        XCTAssertTrue(todayCount.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(todayCount.label, "0", app.debugDescription)
        for period in ["3 meses", "1 ano", "todo histórico", "1 mês"] {
            button(period)
            XCTAssertEqual(todayCount.label, "0", app.debugDescription)
        }
    }

    func testStatisticsReflectsReviewAcrossPeriods() {
        addNote(front: "UI stats reviewed", back: "UI stats answer")
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        button("Mostrar resposta")
        button("study.rating.4")
        XCTAssertTrue(app.staticTexts["Parabéns! Você terminou este baralho por enquanto."]
            .waitForExistence(timeout: 15), app.debugDescription)

        activate(identified("study.close"))
        activate(identified("deck.overview.close"))
        navigate("Estatísticas")

        let todayCount = identified("stats.today.count")
        XCTAssertTrue(todayCount.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(todayCount.label, "1", app.debugDescription)
        for period in ["3 meses", "1 ano", "todo histórico", "1 mês"] {
            button(period)
            XCTAssertEqual(todayCount.label, "1", app.debugDescription)
        }
    }

    #if os(iOS)
    func testStatisticsReviewChartReflectsCurrentLearningReview() {
        addNote(front: "UI stats chart", back: "UI stats chart answer")
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        button("Mostrar resposta")
        button("study.rating.4")
        XCTAssertTrue(app.staticTexts["Parabéns! Você terminou este baralho por enquanto."]
            .waitForExistence(timeout: 15), app.debugDescription)
        activate(identified("study.close"))
        activate(identified("deck.overview.close"))

        navigate("Estatísticas")
        let learningReview = identified("stats.reviews.learn.0")
        XCTAssertTrue(learningReview.waitForExistence(timeout: 15), app.debugDescription)
        reveal(learningReview)
        XCTAssertTrue(learningReview.label.contains("Aprender"), app.debugDescription)
        XCTAssertTrue(learningReview.label.contains("1 revisões")
            || String(describing: learningReview.value ?? "").contains("1 revisões"), app.debugDescription)
    }

    func testStatisticsReviewChartExposesEveryReviewType() {
        finishTutorialIfPresented()
        navigate("Ferramentas")
        button("Importar .apkg, .colpkg ou Mnemosyne .db")

        let fixture = app.cells.matching(
            NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", "ankios-stats-review-types", "ankios-stats-review-types")
        ).firstMatch
        if !fixture.waitForExistence(timeout: 8) {
            let browse = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Explorar")
            ).firstMatch
            if browse.exists { activate(browse) }
            let downloads = app.cells.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Downloads")
            ).firstMatch
            XCTAssertTrue(downloads.waitForExistence(timeout: 10), app.debugDescription)
            activate(downloads)
        }
        XCTAssertTrue(fixture.waitForExistence(timeout: 15), app.debugDescription)
        activate(fixture)
        XCTAssertTrue(app.navigationBars["Importar pacote"].waitForExistence(timeout: 10), app.debugDescription)
        let scheduling = identified("packageImport.scheduling")
        XCTAssertTrue(scheduling.waitForExistence(timeout: 10), app.debugDescription)
        activate(scheduling)
        button("Importar")
        let importMessage = app.alerts.firstMatch
        if importMessage.waitForExistence(timeout: 10) { button("OK") }
        finishTutorialIfPresented()

        navigate("Estatísticas")
        let deckFilter = identified("stats.deckFilter")
        XCTAssertTrue(deckFilter.waitForExistence(timeout: 10), app.debugDescription)
        activate(deckFilter)
        button("Toda a coleção")
        let firstReviewMark = identified("stats.reviews.learn.0")
        XCTAssertTrue(firstReviewMark.waitForExistence(timeout: 15), app.debugDescription)
        let summary = identified("stats.reviews.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10), app.debugDescription)
        for name in ["Aprender", "Jovem", "Maduro", "Reaprender", "Filtrado"] {
            XCTAssertTrue(summary.label.contains("\(name): 1"), summary.label)
        }
    }
    #endif

    func testDisconnectedSyncOpensAnkiWebLoginPanel() {
        let syncAction = app.buttons["Sincronizar com AnkiWeb"].firstMatch
        XCTAssertTrue(syncAction.waitForExistence(timeout: 10), app.debugDescription)
        activate(syncAction)
        XCTAssertTrue(identified("ankiweb.username").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(identified("ankiweb.password").exists, app.debugDescription)
        XCTAssertFalse(identified("ankiweb.endpoint").exists, app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
        activate(identified("ankiweb.login.close"))
        navigate("Ferramentas")
        activate(identified("settings.section.ankiweb"))
        XCTAssertTrue(app.navigationBars["AnkiWeb"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.textFields["Usuário ou e-mail"].exists, app.debugDescription)
        let openLoginPanel = identified("ankiweb.openLoginPanel")
        XCTAssertTrue(openLoginPanel.waitForExistence(timeout: 10), app.debugDescription)
        activate(openLoginPanel)
        XCTAssertTrue(identified("ankiweb.username").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(identified("ankiweb.password").exists, app.debugDescription)
        XCTAssertFalse(identified("ankiweb.endpoint").exists, app.debugDescription)
        activate(identified("ankiweb.login.close"))
        #if os(iOS)
        openAnkiURL(URL(string: "anki://x-callback-url/sync")!)
        XCTAssertTrue(identified("ankiweb.username").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
        activate(identified("ankiweb.login.close"))

        let endpoint = Bundle(for: Self.self).object(forInfoDictionaryKey: "ANKIOS_UI_SYNC_ENDPOINT") as? String
            ?? ProcessInfo.processInfo.environment["ANKIOS_UI_SYNC_ENDPOINT"]
        guard let endpoint,
              URL(string: endpoint)?.host == "127.0.0.1" else { return }

        addNote(front: "UI sync URL question", back: "UI sync URL answer")
        navigate("Ferramentas")
        loginToLocalSync()
        let uploadCollection = identified("ankiweb.fullSync.upload")
        XCTAssertTrue(uploadCollection.waitForExistence(timeout: 30), app.debugDescription)
        activate(uploadCollection)
        assertAnkiWebStatus("Coleção enviada ao AnkiWeb.")
        let syncButton = app.buttons["Sincronizar agora"].firstMatch
        let uploadSettled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: syncButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [uploadSettled], timeout: 30), .completed, app.debugDescription)

        openAnkiURL(URL(string: "anki://x-callback-url/sync")!)
        let idleSyncAction = app.buttons["Sincronizar com AnkiWeb"].firstMatch
        XCTAssertTrue(idleSyncAction.waitForExistence(timeout: 120), app.debugDescription)
        navigate("Ferramentas")
        XCTAssertTrue(
            app.staticTexts["Sincronização com AnkiWeb concluída."].waitForExistence(timeout: 30),
            app.debugDescription
        )
        #endif
    }

    func testStudyTypedAnswerFeedback() throws {
        let package = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "typed-answer", withExtension: "apkg"))
        app.open(package)
        let importButton = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Importar")
        ).firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout: 15), app.debugDescription)
        activate(importButton)
        if importButton.waitForExistence(timeout: 5) {
            activate(importButton)
        }
        finishTutorialIfPresented()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        button("OK")
        finishTutorialIfPresented()
#if os(iOS)
        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let neverTypeSetting = identified("preferences.review.neverTypeAnswer")
        XCTAssertTrue(neverTypeSetting.waitForExistence(timeout: 10), app.debugDescription)
        if "\(neverTypeSetting.value ?? "")" != "1" { activate(neverTypeSetting) }
        activate(identified("preferences.save"))
        let preferencesBack = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(preferencesBack.waitForExistence(timeout: 10), app.debugDescription)
        activate(preferencesBack)
        navigate("Baralhos")
#endif
        activate(app.buttons["deck.open.UI Typed Answer"])
        button("Estudar agora")

#if os(iOS)
        let question = app.webViews.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "UI typed")
        ).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.textFields["Digite a resposta"].exists, app.debugDescription)
        let reveal = identified("study.revealAnswer")
        XCTAssertEqual(reveal.label, "Mostrar resposta", app.debugDescription)
        activate(reveal)
        let expectedAnswer = app.webViews.staticTexts.matching(
            NSPredicate(format: "label IN %@", ["Anki", "Expected"])
        ).firstMatch
        XCTAssertTrue(expectedAnswer.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Resposta diferente do esperado"].exists, app.debugDescription)
#else
        for index in 0..<2 {
            let correctQuestion = app.webViews.staticTexts["UI typed correct question"].firstMatch
            let mismatchQuestion = app.webViews.staticTexts["UI typed mismatch question"].firstMatch
            let question = app.webViews.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "UI typed")
            ).firstMatch
            XCTAssertTrue(question.waitForExistence(timeout: 15), app.debugDescription)
            let isCorrectCase = correctQuestion.exists
            XCTAssertTrue(isCorrectCase || mismatchQuestion.exists, app.debugDescription)

            let answerField = app.textFields["Digite a resposta"].firstMatch
            XCTAssertTrue(answerField.waitForExistence(timeout: 10), app.debugDescription)
            enter(isCorrectCase ? "Anki" : "Wrong", into: answerField)
            button("Verificar")
            let expectedFeedback = isCorrectCase ? "Resposta correta" : "Resposta diferente do esperado"
            XCTAssertTrue(app.staticTexts[expectedFeedback].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(identified("study.rating.3").waitForExistence(timeout: 5), app.debugDescription)
            if index == 0 {
                activate(identified("study.rating.3"))
            }
        }
#endif
    }

    func testCSVImportCancellation() {
        navigate("Ferramentas")
        button("Importar CSV / texto")
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Cancelar"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Cancel não apareceu no seletor CSV")
        activate(cancel)
        XCTAssertTrue(app.buttons["Importar CSV / texto"].waitForExistence(timeout: 10))
    }

    func testCollectionPackageImportCanBeCancelledFromTools() {
        navigate("Ferramentas")
        let importButton = app.buttons["Importar .apkg, .colpkg ou Mnemosyne .db"].firstMatch
        button("Importar .apkg, .colpkg ou Mnemosyne .db")
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Cancelar"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        activate(cancel)
        XCTAssertTrue(importButton.waitForExistence(timeout: 10), app.debugDescription)
    }

    #if os(iOS)
    func testCSVImportThroughToolsMapsFieldsTagsAndStudiesNote() {
        finishTutorialIfPresented()
        navigate("Ferramentas")
        button("Importar CSV / texto")

        let fixtureName = "ankios-tools-import-fixture"
        let fixture = app.cells.matching(
            NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", fixtureName, fixtureName)
        ).firstMatch
        if !fixture.waitForExistence(timeout: 8) {
            let browse = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Explorar", "Browse")
            ).firstMatch
            if browse.exists { activate(browse) }
            if !fixture.waitForExistence(timeout: 8) {
                let downloads = app.cells.matching(
                    NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Downloads", "Transferências")
                ).firstMatch
                if downloads.exists { activate(downloads) }
            }
        }
        XCTAssertTrue(fixture.waitForExistence(timeout: 15), app.debugDescription)
        activate(fixture)

        XCTAssertTrue(app.navigationBars["Importar texto"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["UI CSV question"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["UI CSV answer"].exists, app.debugDescription)
        let headerToggle = identified("csv.skipFirstRow")
        XCTAssertTrue(headerToggle.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(headerToggle.value as? String, "1", app.debugDescription)
        XCTAssertTrue(app.staticTexts["Front"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Back"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Tags"].exists, app.debugDescription)
        enter("parityglobal", into: identified("csv.tagsForAllNotes"))
        button("Importar")
        let completion = identified("csv.import.summary")
        XCTAssertTrue(completion.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue((completion.label).contains("1 nova"), app.debugDescription)
        XCTAssertFalse(completion.label.contains("não foram salvas"), app.debugDescription)
        button("OK")
        let tutorialSkip = app.buttons["Pular"].firstMatch
        if tutorialSkip.waitForExistence(timeout: 8) {
            activate(tutorialSkip)
        } else {
            finishTutorialIfPresented()
        }

        navigate("Painel")
        search("tag:paritycsv")
        XCTAssertTrue(app.staticTexts["UI CSV question"].waitForExistence(timeout: 15), app.debugDescription)
        search("tag:parityglobal")
        XCTAssertTrue(app.staticTexts["UI CSV question"].waitForExistence(timeout: 10), app.debugDescription)

        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        XCTAssertTrue(app.webViews.staticTexts["UI CSV question"].waitForExistence(timeout: 15), app.debugDescription)
        button("Mostrar resposta")
        XCTAssertTrue(app.webViews.staticTexts["UI CSV answer"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testCSVImportCanIgnoreAnExistingNoteThroughTools() {
        addNote(front: "UI CSV question", back: "UI CSV original answer", tags: "paritycsv")
        navigate("Ferramentas")
        button("Importar CSV / texto")

        let fixtureName = "ankios-tools-import-fixture"
        let fixture = app.cells.matching(
            NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", fixtureName, fixtureName)
        ).firstMatch
        if !fixture.waitForExistence(timeout: 8) {
            let browse = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Explorar", "Browse")
            ).firstMatch
            if browse.exists { activate(browse) }
            if !fixture.waitForExistence(timeout: 8) {
                let downloads = app.cells.matching(
                    NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Downloads", "Transferências")
                ).firstMatch
                if downloads.exists { activate(downloads) }
            }
        }
        XCTAssertTrue(fixture.waitForExistence(timeout: 15), app.debugDescription)
        activate(fixture)

        XCTAssertTrue(app.navigationBars["Importar texto"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["UI CSV question"].waitForExistence(timeout: 10), app.debugDescription)
        button("Atualizar nota existente")
        button("Ignorar duplicatas")
        button("Importar")

        let summary = identified("csv.import.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(summary.label.contains("0 nova(s)"), app.debugDescription)
        XCTAssertTrue(summary.label.contains("0 atualizada(s)"), app.debugDescription)
        XCTAssertTrue(summary.label.contains("1 ignorada(s)"), app.debugDescription)
        button("OK")

        navigate("Painel")
        search("tag:paritycsv")
        XCTAssertTrue(app.staticTexts["UI CSV question"].waitForExistence(timeout: 15), app.debugDescription)
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        XCTAssertTrue(app.webViews.staticTexts["UI CSV question"].waitForExistence(timeout: 15), app.debugDescription)
        button("Mostrar resposta")
        XCTAssertTrue(app.webViews.staticTexts["UI CSV original answer"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testCSVImportUpdatesAnExistingNoteThroughTools() {
        addNote(front: "UI CSV question", back: "UI CSV original answer", tags: "paritycsv")
        navigate("Ferramentas")
        button("Importar CSV / texto")

        let fixtureName = "ankios-tools-import-fixture"
        let fixture = app.cells.matching(
            NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", fixtureName, fixtureName)
        ).firstMatch
        if !fixture.waitForExistence(timeout: 8) {
            let browse = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Explorar", "Browse")
            ).firstMatch
            if browse.exists { activate(browse) }
            if !fixture.waitForExistence(timeout: 8) {
                let downloads = app.cells.matching(
                    NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Downloads", "Transferências")
                ).firstMatch
                if downloads.exists { activate(downloads) }
            }
        }
        XCTAssertTrue(fixture.waitForExistence(timeout: 15), app.debugDescription)
        activate(fixture)

        XCTAssertTrue(app.navigationBars["Importar texto"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["Atualizar nota existente"].waitForExistence(timeout: 5), app.debugDescription)
        enter("parityupdated", into: identified("csv.tagsForUpdatedNotes"))
        button("Importar")

        let updateSummary = identified("csv.import.summary")
        XCTAssertTrue(updateSummary.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(updateSummary.label.contains("0 nova(s)"), app.debugDescription)
        XCTAssertTrue(updateSummary.label.contains("1 atualizada(s)"), app.debugDescription)
        XCTAssertTrue(updateSummary.label.contains("0 ignorada(s)"), app.debugDescription)
        button("OK")

        navigate("Painel")
        search("tag:parityupdated")
        XCTAssertTrue(app.staticTexts["UI CSV question"].waitForExistence(timeout: 10), app.debugDescription)
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        XCTAssertTrue(app.webViews.staticTexts["UI CSV question"].waitForExistence(timeout: 15), app.debugDescription)
        button("Mostrar resposta")
        XCTAssertTrue(app.webViews.staticTexts["UI CSV answer"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testCSVImportAsNewCreatesAnotherNoteThroughTools() {
        addNote(front: "UI CSV question", back: "UI CSV original answer", tags: "paritycsv")
        navigate("Ferramentas")
        button("Importar CSV / texto")

        let fixtureName = "ankios-tools-import-fixture"
        let fixture = app.cells.matching(
            NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", fixtureName, fixtureName)
        ).firstMatch
        if !fixture.waitForExistence(timeout: 8) {
            let browse = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Explorar", "Browse")
            ).firstMatch
            if browse.exists { activate(browse) }
            if !fixture.waitForExistence(timeout: 8) {
                let downloads = app.cells.matching(
                    NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Downloads", "Transferências")
                ).firstMatch
                if downloads.exists { activate(downloads) }
            }
        }
        XCTAssertTrue(fixture.waitForExistence(timeout: 15), app.debugDescription)
        activate(fixture)

        XCTAssertTrue(app.navigationBars["Importar texto"].waitForExistence(timeout: 10), app.debugDescription)
        button("Atualizar nota existente")
        button("Importar como novas notas")
        button("Importar")

        let summary = identified("csv.import.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(summary.label.contains("1 nova(s)"), app.debugDescription)
        XCTAssertTrue(summary.label.contains("0 atualizada(s)"), app.debugDescription)
        XCTAssertTrue(summary.label.contains("0 ignorada(s)"), app.debugDescription)
        button("OK")
        let tutorialSkip = app.buttons["Pular"].firstMatch
        if tutorialSkip.waitForExistence(timeout: 8) {
            activate(tutorialSkip)
        } else {
            finishTutorialIfPresented()
        }

        navigate("Painel")
        search("tag:paritycsv")
        let importedQuestions = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "UI CSV question")
        )
        XCTAssertEqual(importedQuestions.count, 2, app.debugDescription)
    }

    func testCSVImportOptionsPersistAfterRelaunch() {
        finishTutorialIfPresented()

        func selectFixture() {
            let fixtureName = "ankios-tools-import-fixture"
            let fixture = app.cells.matching(
                NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", fixtureName, fixtureName)
            ).firstMatch
            if !fixture.waitForExistence(timeout: 8) {
                let browse = app.buttons.matching(
                    NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Explorar", "Browse")
                ).firstMatch
                if browse.exists { activate(browse) }
                if !fixture.waitForExistence(timeout: 8) {
                    let downloads = app.cells.matching(
                        NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Downloads", "Transferências")
                    ).firstMatch
                    if downloads.exists { activate(downloads) }
                }
            }
            XCTAssertTrue(fixture.waitForExistence(timeout: 15), app.debugDescription)
            activate(fixture)
        }

        navigate("Ferramentas")
        button("Importar CSV / texto")
        selectFixture()
        XCTAssertTrue(app.navigationBars["Importar texto"].waitForExistence(timeout: 10), app.debugDescription)

        let allowHTML = identified("csv.allowHTML")
        let matchWithinDeck = identified("csv.matchWithinDeck")
        XCTAssertEqual(allowHTML.value as? String, "1", app.debugDescription)
        XCTAssertEqual(matchWithinDeck.value as? String, "0", app.debugDescription)
        activate(allowHTML)
        activate(matchWithinDeck)
        enter("parityall", into: identified("csv.tagsForAllNotes"))
        button("Importar")

        let summary = identified("csv.import.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(summary.label.contains("1 nova"), app.debugDescription)
        button("OK")
        let tutorialSkip = app.buttons["Pular"].firstMatch
        if tutorialSkip.waitForExistence(timeout: 8) {
            activate(tutorialSkip)
        } else {
            finishTutorialIfPresented()
        }

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Baralhos"].waitForExistence(timeout: 20), app.debugDescription)
        navigate("Ferramentas")
        button("Importar CSV / texto")
        selectFixture()
        XCTAssertTrue(app.navigationBars["Importar texto"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(identified("csv.skipFirstRow").value as? String, "1", app.debugDescription)
        XCTAssertEqual(identified("csv.allowHTML").value as? String, "0", app.debugDescription)
        XCTAssertEqual(identified("csv.matchWithinDeck").value as? String, "1", app.debugDescription)
        XCTAssertEqual(identified("csv.tagsForAllNotes").value as? String, "parityall", app.debugDescription)
        button("Cancelar")
    }

    func testCSVImportMatchesDuplicatesOnlyWithinSelectedDeck() {
        addNote(front: "UI CSV question", back: "UI CSV original answer")
        createDeck("UI CSV Match")

        navigate("Ferramentas")
        button("Importar CSV / texto")
        let fixtureName = "ankios-tools-import-fixture"
        let fixture = app.cells.matching(
            NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", fixtureName, fixtureName)
        ).firstMatch
        if !fixture.waitForExistence(timeout: 8) {
            let browse = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Explorar", "Browse")
            ).firstMatch
            if browse.exists { activate(browse) }
            if !fixture.waitForExistence(timeout: 8) {
                let downloads = app.cells.matching(
                    NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Downloads", "Transferências")
                ).firstMatch
                if downloads.exists { activate(downloads) }
            }
        }
        XCTAssertTrue(fixture.waitForExistence(timeout: 15), app.debugDescription)
        activate(fixture)
        XCTAssertTrue(app.navigationBars["Importar texto"].waitForExistence(timeout: 10), app.debugDescription)

        let deckPicker = identified("csv.deck")
        XCTAssertTrue(deckPicker.waitForExistence(timeout: 10), app.debugDescription)
        activate(deckPicker)
        button("UI CSV Match")
        let matchWithinDeck = identified("csv.matchWithinDeck")
        reveal(matchWithinDeck)
        XCTAssertEqual(matchWithinDeck.value as? String, "0", app.debugDescription)
        activate(matchWithinDeck)
        XCTAssertEqual(matchWithinDeck.value as? String, "1", app.debugDescription)
        button("Importar")

        let summary = identified("csv.import.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(summary.label.contains("1 nova(s)"), app.debugDescription)
        XCTAssertTrue(summary.label.contains("0 atualizada(s)"), app.debugDescription)
        XCTAssertTrue(summary.label.contains("0 ignorada(s)"), app.debugDescription)
        button("OK")

        navigate("Painel")
        search("deck:\"Default\" UI CSV question")
        XCTAssertTrue(app.staticTexts["UI CSV question"].waitForExistence(timeout: 10), app.debugDescription)
        search("deck:\"UI CSV Match\" UI CSV question")
        XCTAssertTrue(app.staticTexts["UI CSV question"].waitForExistence(timeout: 10), app.debugDescription)

        navigate("Baralhos")
        activate(app.buttons["deck.open.UI CSV Match"])
        button("Estudar agora")
        button("Mostrar resposta")
        XCTAssertTrue(app.webViews.staticTexts["UI CSV answer"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testCSVImportSemicolonAndHTMLThroughTools() {
        finishTutorialIfPresented()
        navigate("Ferramentas")
        button("Importar CSV / texto")

        let fixtureName = "ankios-tools-html-import-fixture"
        let fixture = app.cells.matching(
            NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", fixtureName, fixtureName)
        ).firstMatch
        if !fixture.waitForExistence(timeout: 8) {
            let browse = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Explorar", "Browse")
            ).firstMatch
            if browse.exists { activate(browse) }
            if !fixture.waitForExistence(timeout: 8) {
                let downloads = app.cells.matching(
                    NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Downloads", "Transferências")
                ).firstMatch
                if downloads.exists { activate(downloads) }
            }
        }
        XCTAssertTrue(fixture.waitForExistence(timeout: 15), app.debugDescription)
        activate(fixture)

        XCTAssertTrue(app.navigationBars["Importar texto"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(identified("csv.skipFirstRow").value as? String, "1", app.debugDescription)
        button("Importar")

        let summary = identified("csv.import.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(summary.label.contains("1 nova"), app.debugDescription)
        button("OK")
        let tutorialSkip = app.buttons["Pular"].firstMatch
        if tutorialSkip.waitForExistence(timeout: 8) {
            activate(tutorialSkip)
        } else {
            finishTutorialIfPresented()
        }

        navigate("Painel")
        search("tag:paritycsvhtml")
        XCTAssertTrue(app.staticTexts["UI HTML question"].waitForExistence(timeout: 15), app.debugDescription)
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        XCTAssertTrue(app.webViews.staticTexts["UI HTML question"].waitForExistence(timeout: 15), app.debugDescription)
        button("Mostrar resposta")
        XCTAssertTrue(app.webViews.staticTexts["UI HTML answer"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testCollectionPackageImportThroughToolsAndStudiesImportedMedia() {
        finishTutorialIfPresented()
        navigate("Ferramentas")
        button("Importar .apkg, .colpkg ou Mnemosyne .db")

        let fixture = app.cells.matching(
            NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", "ankios-tools-import-fixture", "ankios-tools-import-fixture")
        ).firstMatch
        if !fixture.waitForExistence(timeout: 8) {
            let browse = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Explorar")
            ).firstMatch
            if browse.exists { activate(browse) }
            let downloads = app.cells.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Downloads")
            ).firstMatch
            XCTAssertTrue(downloads.waitForExistence(timeout: 10), app.debugDescription)
            activate(downloads)
        }
        XCTAssertTrue(fixture.waitForExistence(timeout: 15), app.debugDescription)
        activate(fixture)

        XCTAssertTrue(app.navigationBars["Importar pacote"].waitForExistence(timeout: 10), app.debugDescription)
        button("Importar")
        let tutorialSkip = app.buttons["Pular"].firstMatch
        if tutorialSkip.waitForExistence(timeout: 10) {
            activate(tutorialSkip)
        }
        let importMessage = app.alerts.firstMatch
        if importMessage.waitForExistence(timeout: 5) {
            button("OK")
        }

        navigate("Baralhos")
        let importedDeck = app.buttons["deck.open.UI Imported"].firstMatch
        XCTAssertTrue(importedDeck.waitForExistence(timeout: 30), app.debugDescription)
        activate(importedDeck)
        button("Estudar agora")
        XCTAssertTrue(app.webViews.staticTexts["UI imported question"].waitForExistence(timeout: 15), app.debugDescription)
        button("Mostrar resposta")
        let question = app.webViews.staticTexts["UI imported question"].firstMatch
        let answer = app.webViews.staticTexts["UI imported answer"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertLessThan(question.frame.midY, answer.frame.midY, app.debugDescription)
        XCTAssertTrue(app.webViews.images.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.webViews.buttons["Reproduzir áudio"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testApkgImportOptionsAndPoliciesArePresentedBeforeImport() {
        finishTutorialIfPresented()
        navigate("Ferramentas")
        button("Importar .apkg, .colpkg ou Mnemosyne .db")

        let fixture = app.cells.matching(
            NSPredicate(format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@", "ankios-tools-import-fixture", "ankios-tools-import-fixture")
        ).firstMatch
        if !fixture.waitForExistence(timeout: 8) {
            let browse = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Explorar")
            ).firstMatch
            if browse.exists { activate(browse) }
            let downloads = app.cells.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Downloads")
            ).firstMatch
            XCTAssertTrue(downloads.waitForExistence(timeout: 10), app.debugDescription)
            activate(downloads)
        }
        XCTAssertTrue(fixture.waitForExistence(timeout: 15), app.debugDescription)
        activate(fixture)
        XCTAssertTrue(app.navigationBars["Importar pacote"].waitForExistence(timeout: 10), app.debugDescription)

        let scheduling = identified("packageImport.scheduling")
        let deckConfigs = identified("packageImport.deckConfigs")
        let mergeNotetypes = identified("packageImport.mergeNotetypes")
        XCTAssertTrue(scheduling.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(scheduling.value as? String, "0", app.debugDescription)
        XCTAssertEqual(deckConfigs.value as? String, "0", app.debugDescription)
        XCTAssertEqual(mergeNotetypes.value as? String, "0", app.debugDescription)
        activate(scheduling)
        activate(deckConfigs)
        activate(mergeNotetypes)
        XCTAssertEqual(scheduling.value as? String, "1", app.debugDescription)
        XCTAssertEqual(deckConfigs.value as? String, "1", app.debugDescription)
        XCTAssertEqual(mergeNotetypes.value as? String, "1", app.debugDescription)

        button("Atualizações")
        let updateNotes = identified("packageImport.updateNotes")
        let updateNotetypes = identified("packageImport.updateNotetypes")
        XCTAssertTrue(updateNotes.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(updateNotetypes.waitForExistence(timeout: 10), app.debugDescription)
        activate(updateNotes)
        let alwaysUpdateNotes = identified("packageImport.updateNotes.choice.always")
        XCTAssertTrue(alwaysUpdateNotes.waitForExistence(timeout: 10), app.debugDescription)
        activate(alwaysUpdateNotes)
        XCTAssertEqual(updateNotes.value as? String, "Sempre", app.debugDescription)
        reveal(updateNotetypes)
        XCTAssertTrue(updateNotetypes.isHittable, app.debugDescription)
        activate(updateNotetypes)
        let neverUpdateNotetypes = identified("packageImport.updateNotetypes.choice.never")
        XCTAssertTrue(neverUpdateNotetypes.waitForExistence(timeout: 10), app.debugDescription)
        activate(neverUpdateNotetypes)
        XCTAssertEqual(updateNotetypes.value as? String, "Nunca", app.debugDescription)

        button("Importar")
        let tutorialSkip = app.buttons["Pular"].firstMatch
        if tutorialSkip.waitForExistence(timeout: 10) {
            activate(tutorialSkip)
        }
        let importMessage = app.alerts.firstMatch
        if importMessage.waitForExistence(timeout: 10) {
            button("OK")
        }
        finishTutorialIfPresented()
        navigate("Baralhos")
        let importedDeck = app.buttons["deck.open.UI Imported"].firstMatch
        XCTAssertTrue(importedDeck.waitForExistence(timeout: 30), app.debugDescription)
    }
    #endif

    func testBrowserTagDeleteAndUndo() {
        addNote()
        navigate("Painel")
        search("UI question")
        activate(app.staticTexts["UI question"].firstMatch)
        activate(identified("browser.actions.menu"))
        activate(identified("browser.addTag"))
        #if os(macOS)
        let addTagField = app.textFields["tag"].firstMatch
        #else
        let addTagField = app.alerts.textFields.firstMatch
        #endif
        enter("ui-tag", into: addTagField)
        button("OK")
        search("tag:ui-tag")
        XCTAssertTrue(app.staticTexts["UI question"].firstMatch.waitForExistence(timeout: 10))
        activate(identified("browser.actions.menu"))
        activate(identified("browser.selectAll"))
        activate(identified("browser.actions.menu"))
        menuButton("Apagar…")
        menuButton("Apagar notas")
        XCTAssertTrue(app.staticTexts["Nenhum cartão"].waitForExistence(timeout: 10))
        button("Desfazer")
        XCTAssertTrue(app.staticTexts["UI question"].firstMatch.waitForExistence(timeout: 10))
    }

    func testBrowserBulkTagReplacementAndUndo() {
        addNote(front: "UI Tag Alpha", back: "UI Tag answer Alpha")
        addNote(front: "UI Tag Beta", back: "UI Tag answer Beta")
        navigate("Painel")
        search("UI Tag")

        activate(identified("browser.actions.menu"))
        activate(identified("browser.selectAll"))
        activate(identified("browser.actions.menu"))
        activate(identified("browser.addTag"))
        #if os(macOS)
        let addTagField = app.textFields["tag"].firstMatch
        #else
        let addTagField = app.alerts.textFields.firstMatch
        #endif
        enter("old-ui-tag", into: addTagField)
        button("OK")

        search("tag:old-ui-tag")
        XCTAssertTrue(app.staticTexts["UI Tag Alpha"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["UI Tag Beta"].exists, app.debugDescription)

        activate(identified("browser.actions.menu"))
        activate(identified("browser.selectAll"))
        activate(identified("browser.actions.menu"))
        menuButton("Substituir tag…")
        #if os(macOS)
        let fromTagField = app.textFields["De"].firstMatch
        let toTagField = app.textFields["Para"].firstMatch
        #else
        let fromTagField = app.alerts.textFields["De"].firstMatch
        let toTagField = app.alerts.textFields["Para"].firstMatch
        #endif
        enter("old-ui-tag", into: fromTagField)
        enter("new-ui-tag", into: toTagField)
        button("OK")

        search("tag:new-ui-tag")
        XCTAssertTrue(app.staticTexts["UI Tag Alpha"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["UI Tag Beta"].exists, app.debugDescription)
        search("tag:old-ui-tag")
        XCTAssertTrue(app.staticTexts["Nenhum cartão"].waitForExistence(timeout: 10), app.debugDescription)

        button("Desfazer")
        search("tag:old-ui-tag")
        XCTAssertTrue(app.staticTexts["UI Tag Alpha"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["UI Tag Beta"].exists, app.debugDescription)
    }

    func testBrowserSetDueAndUndo() {
        addNote(front: "UI Due question", back: "UI Due answer")
        navigate("Painel")
        search("UI Due question")

        activate(identified("browser.actions.menu"))
        activate(identified("browser.selectAll"))
        activate(identified("browser.actions.menu"))
        menuButton("Definir due…")
        #if os(macOS)
        let dueField = app.textFields["5, 0-2 ou 60-90!"].firstMatch
        #else
        let dueField = app.alerts.textFields["5, 0-2 ou 60-90!"].firstMatch
        #endif
        XCTAssertTrue(dueField.waitForExistence(timeout: 10), app.debugDescription)
        enter("5", into: dueField)
        button("OK")

        search("is:review")
        XCTAssertTrue(app.staticTexts["UI Due question"].waitForExistence(timeout: 10), app.debugDescription)
        button("Desfazer")
        search("is:new")
        XCTAssertTrue(app.staticTexts["UI Due question"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testBrowserBulkMarkBuryAndFlagAndUndo() {
        addNote(front: "UI Actions Alpha", back: "UI Actions answer Alpha")
        addNote(front: "UI Actions Beta", back: "UI Actions answer Beta")
        navigate("Painel")
        search("UI Actions")

        activate(app.staticTexts["UI Actions Alpha"].firstMatch)
        activate(identified("browser.actions.menu"))
        activate(identified("browser.selection.notes"))
        let notesMode = app.buttons["Notas"].firstMatch
        XCTAssertTrue(notesMode.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(notesMode.isSelected, app.debugDescription)

        search("UI Actions")
        activate(app.staticTexts["UI Actions Alpha"].firstMatch)
        activate(identified("browser.actions.menu"))
        activate(identified("browser.selection.invert"))
        activate(identified("browser.actions.menu"))
        activate(identified("browser.selection.mark"))
        search("tag:marked")
        XCTAssertTrue(app.staticTexts["UI Actions Beta"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.staticTexts["UI Actions Alpha"].exists, app.debugDescription)
        button("Desfazer")
        search("UI Actions")

        activate(identified("browser.actions.menu"))
        activate(identified("browser.selectAll"))
        activate(identified("browser.actions.menu"))
        activate(identified("browser.selection.mark"))
        search("tag:marked")
        XCTAssertTrue(app.staticTexts["UI Actions Alpha"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["UI Actions Beta"].exists, app.debugDescription)
        button("Desfazer")
        search("tag:marked")
        XCTAssertTrue(app.staticTexts["Nenhum cartão"].waitForExistence(timeout: 10), app.debugDescription)

        search("UI Actions")
        activate(identified("browser.actions.menu"))
        activate(identified("browser.selectAll"))
        activate(identified("browser.actions.menu"))
        activate(identified("browser.selection.bury"))
        search("is:buried")
        XCTAssertTrue(app.staticTexts["UI Actions Alpha"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["UI Actions Beta"].exists, app.debugDescription)
        button("Desfazer")
        search("is:buried")
        XCTAssertTrue(app.staticTexts["Nenhum cartão"].waitForExistence(timeout: 10), app.debugDescription)

        search("UI Actions")
        activate(identified("browser.actions.menu"))
        activate(identified("browser.selectAll"))
        activate(identified("browser.actions.menu"))
        activate(identified("flag"))
        #if os(macOS)
        activate(app.menuItems["Vermelho"].firstMatch)
        #else
        menuButton("Vermelho")
        #endif
        search("flag:1")
        XCTAssertTrue(app.staticTexts["UI Actions Alpha"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["UI Actions Beta"].exists, app.debugDescription)
        button("Desfazer")
        search("flag:1")
        XCTAssertTrue(app.staticTexts["Nenhum cartão"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testBrowserMoveSelectedCardsAndUndo() {
        createDeck("UI Move Target")
        addNote(front: "UI Move question", back: "UI Move answer")
        navigate("Painel")
        search("UI Move question")

        activate(identified("browser.actions.menu"))
        activate(identified("browser.selectAll"))
        activate(identified("browser.actions.menu"))
        menuButton("Mover…")
        XCTAssertTrue(app.navigationBars["Mover para baralho"].waitForExistence(timeout: 10), app.debugDescription)
        activate(app.buttons["UI Move Target"].firstMatch)

        search("deck:\"UI Move Target\"")
        XCTAssertTrue(app.staticTexts["UI Move question"].waitForExistence(timeout: 10), app.debugDescription)
        search("deck:\"Default\"")
        XCTAssertTrue(app.staticTexts["Nenhum cartão"].waitForExistence(timeout: 10), app.debugDescription)

        button("Desfazer")
        search("deck:\"Default\"")
        XCTAssertTrue(app.staticTexts["UI Move question"].waitForExistence(timeout: 10), app.debugDescription)
        search("deck:\"UI Move Target\"")
        XCTAssertTrue(app.staticTexts["Nenhum cartão"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testBrowserForgetReviewedCardAndUndo() {
        addNote(front: "UI Reset question", back: "UI Reset answer")
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")
        activate(identified("study.revealAnswer"))
        activate(identified("study.rating.3"))
        activate(identified("study.close"))
        activate(identified("deck.overview.close"))

        navigate("Painel")
        search("is:learn")
        XCTAssertTrue(app.staticTexts["UI Reset question"].waitForExistence(timeout: 10), app.debugDescription)
        search("UI Reset question")
        activate(identified("browser.actions.menu"))
        activate(identified("browser.selectAll"))
        activate(identified("browser.actions.menu"))
        #if os(macOS)
        activate(identified("browser.forgetCards"))
        #else
        menuButton("Repor (esquecer)…")
        #endif
        #if os(macOS)
        XCTAssertTrue(app.staticTexts["Repor cartões"].waitForExistence(timeout: 10), app.debugDescription)
        #else
        XCTAssertTrue(app.navigationBars["Repor cartões"].waitForExistence(timeout: 10), app.debugDescription)
        #endif
        button("Repor cartões")

        search("is:new")
        XCTAssertTrue(app.staticTexts["UI Reset question"].waitForExistence(timeout: 10), app.debugDescription)
        button("Desfazer")
        search("is:learn")
        XCTAssertTrue(app.staticTexts["UI Reset question"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testBrowserColumnsCanBeHiddenAndRestored() {
        addNote(front: "UI Columns question", back: "UI Columns answer")
        navigate("Painel")
        search("UI Columns question")
        let dueColumn = app.staticTexts.matching(
            NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@ OR value BEGINSWITH %@",
                "Vencimento",
                "Vencimento:",
                "Vencimento"
            )
        ).firstMatch
        XCTAssertTrue(dueColumn.waitForExistence(timeout: 10), app.debugDescription)

        button("Colunas")
        menuButton("Vencimento")
        XCTAssertFalse(dueColumn.waitForExistence(timeout: 2), app.debugDescription)
        navigate("Baralhos")
        navigate("Painel")
        search("UI Columns question")
        XCTAssertFalse(dueColumn.exists, app.debugDescription)

        button("Colunas")
        menuButton("Vencimento")
        XCTAssertTrue(dueColumn.waitForExistence(timeout: 10), app.debugDescription)
    }

    func testBrowserSavedSearchCanBeReapplied() {
        addNote(front: "UI Saved question", back: "UI Saved answer")
        navigate("Painel")
        search("UI Saved")
        XCTAssertTrue(app.staticTexts["UI Saved question"].waitForExistence(timeout: 10), app.debugDescription)

        activate(identified("browser.savedSearch.menu"))
        #if os(macOS)
        activate(identified("browser.savedSearch.saveCurrent"))
        #else
        let saveCurrent = identified("browser.savedSearch.saveCurrent")
        XCTAssertTrue(saveCurrent.waitForExistence(timeout: 5), app.debugDescription)
        activate(saveCurrent)
        #endif
        #if os(macOS)
        let searchName = app.textFields["Nome da busca"].firstMatch
        #else
        let searchName = app.alerts.textFields["Nome da busca"].firstMatch
        #endif
        XCTAssertTrue(searchName.waitForExistence(timeout: 10), app.debugDescription)
        let previousName = searchName.value as? String ?? ""
        searchName.tap()
        searchName.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previousName.count))
        type("UI Saved Search", into: searchName)
        XCTAssertEqual(searchName.value as? String, "UI Saved Search", app.debugDescription)
        button("Salvar")
        search("is:review")
        XCTAssertTrue(app.staticTexts["Nenhum cartão"].waitForExistence(timeout: 10), app.debugDescription)

        activate(identified("browser.savedSearch.menu"))
        let savedSearchItem = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "browser.savedSearch.item.UI Saved Search")
        ).firstMatch
        XCTAssertTrue(savedSearchItem.waitForExistence(timeout: 5), app.debugDescription)
        activate(savedSearchItem)
        XCTAssertTrue(app.staticTexts["UI Saved question"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testBrowserRepositionSelectedNewCardAndUndo() {
        addNote(front: "UI Reposition question", back: "UI Reposition answer")
        navigate("Painel")
        search("UI Reposition question")

        activate(identified("browser.actions.menu"))
        activate(identified("browser.selectAll"))
        activate(identified("browser.actions.menu"))
        #if os(macOS)
        activate(identified("browser.reposition"))
        #else
        menuButton("Reposicionar Novos Cartões")
        #endif
        let startingPosition = identified("browser.reposition.start")
        XCTAssertTrue(startingPosition.waitForExistence(timeout: 10), app.debugDescription)
        incrementStepper(startingPosition, times: 5)
        button("Reposicionar")

        XCTAssertTrue(browserDueValue("5").waitForExistence(timeout: 10), app.debugDescription)
        button("Desfazer")
        XCTAssertTrue(browserDueValue("1").waitForExistence(timeout: 10), app.debugDescription)
    }

    func testBrowserBulkFindReplaceAndUndo() {
        addNote(front: "UI Replace Alpha", back: "UI Replace answer Alpha")
        addNote(front: "UI Replace Beta", back: "UI Replace answer Beta")
        navigate("Painel")
        search("UI Replace")

        activate(identified("browser.actions.menu"))
        activate(identified("browser.selectAll"))
        activate(identified("browser.actions.menu"))
        #if os(macOS)
        activate(identified("browser.findReplace"))
        #else
        menuButton("Localizar e Substituir")
        #endif
        enter("Replace", into: app.textFields["Texto para localizar"].firstMatch)
        enter("Changed", into: app.textFields["Substituir nos campos"].firstMatch)
        button("Substituir")
        let replacementStatus = identified("browser.operation.status")
        XCTAssertTrue(replacementStatus.waitForExistence(timeout: 5), app.debugDescription)
        let replacementStatusText = replacementStatus.label + " " + (replacementStatus.value as? String ?? "")
        XCTAssertTrue(replacementStatusText.contains("2"), app.debugDescription)

        search("UI Changed Alpha")
        XCTAssertTrue(app.staticTexts["UI Changed Alpha"].waitForExistence(timeout: 10), app.debugDescription)
        search("UI Changed Beta")
        XCTAssertTrue(app.staticTexts["UI Changed Beta"].waitForExistence(timeout: 10), app.debugDescription)
        search("UI Replace Alpha")
        XCTAssertTrue(app.staticTexts["Nenhum cartão"].waitForExistence(timeout: 10), app.debugDescription)

        button("Desfazer")
        search("UI Replace Alpha")
        XCTAssertTrue(app.staticTexts["UI Replace Alpha"].waitForExistence(timeout: 10), app.debugDescription)
        search("UI Replace Beta")
        XCTAssertTrue(app.staticTexts["UI Replace Beta"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testBrowserSortDirectionAndNotesMode() {
        addNote(front: "UI Sort C", back: "UI Sort answer C")
        addNote(front: "UI Sort A", back: "UI Sort answer A")
        addNote(front: "UI Sort B", back: "UI Sort answer B")
        navigate("Painel")
        search("UI Sort")

        let rowA = app.staticTexts["UI Sort A"].firstMatch
        let rowB = app.staticTexts["UI Sort B"].firstMatch
        let rowC = app.staticTexts["UI Sort C"].firstMatch
        XCTAssertTrue(rowA.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(rowB.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(rowC.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertLessThan(rowA.frame.minY, rowB.frame.minY, app.debugDescription)
        XCTAssertLessThan(rowB.frame.minY, rowC.frame.minY, app.debugDescription)

        button("Ordem crescente")
        let descending = app.buttons["Ordem decrescente"].firstMatch
        XCTAssertTrue(descending.waitForExistence(timeout: 5), app.debugDescription)
        let sortedScreenshot = XCTAttachment(screenshot: app.screenshot())
        sortedScreenshot.name = "Navegador após inverter a ordem"
        sortedScreenshot.lifetime = .keepAlways
        add(sortedScreenshot)
        XCTAssertLessThan(rowC.frame.minY, rowB.frame.minY, app.debugDescription)
        XCTAssertLessThan(rowB.frame.minY, rowA.frame.minY, app.debugDescription)

        navigate("Baralhos")
        navigate("Painel")
        search("UI Sort")
        XCTAssertTrue(app.staticTexts["UI Sort C"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertLessThan(rowC.frame.minY, rowB.frame.minY, app.debugDescription)

        #if os(macOS)
        let radioNotesMode = app.radioButtons["Notas"].firstMatch
        let segmentedNotesMode = app.segmentedControls.buttons["Notas"].firstMatch
        let notesMode = radioNotesMode.exists ? radioNotesMode : segmentedNotesMode
        XCTAssertTrue(notesMode.waitForExistence(timeout: 5), app.debugDescription)
        #else
        let notesMode = app.buttons["Notas"].firstMatch
        #endif
        activate(notesMode)
        XCTAssertTrue(app.staticTexts["UI Sort A"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["UI Sort B"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["UI Sort C"].exists, app.debugDescription)
    }

    func testBrowserSearchSupportsStatusAndAddedOperators() {
        addNote(front: "UI Search Alpha", back: "UI Search answer Alpha")
        addNote(front: "UI Search Beta", back: "UI Search answer Beta")
        navigate("Painel")

        for query in ["is:new", "added:1", "is:new OR is:review", "-is:suspended"] {
            search(query)
            XCTAssertTrue(app.staticTexts["UI Search Alpha"].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.staticTexts["UI Search Beta"].exists, app.debugDescription)
        }

        search("is:review")
        XCTAssertTrue(app.staticTexts["Nenhum cartão"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testBrowserExportsSelectedNotesAsTSV() {
        addNote(front: "UI Export question", back: "UI Export answer")
        navigate("Painel")
        search("UI Export question")
        activate(identified("browser.actions.menu"))
        activate(identified("browser.selectAll"))
        activate(identified("browser.actions.menu"))
        #if os(macOS)
        activate(identified("browser.export.tsv"))
        #else
        menuButton("Exportar seleção (TSV)")
        #endif

        let shareSheet = identified("browser.export.share-sheet")
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 10), app.debugDescription)
    }

    func testBrowserExportsSelectedCardsAsAPKG() {
        addNote(front: "UI APKG question", back: "UI APKG answer")
        navigate("Painel")
        search("UI APKG question")
        activate(identified("browser.actions.menu"))
        activate(identified("browser.selectAll"))
        activate(identified("browser.actions.menu"))
        #if os(macOS)
        activate(identified("browser.export.apkg"))
        #else
        menuButton("Exportar seleção (.apkg)")
        #endif

        let shareSheet = identified("browser.export.share-sheet")
        #if os(macOS)
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 60), app.debugDescription)
        #else
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 15), app.debugDescription)
        #endif
    }

    func testBrowserCardPreviewSwitchesQuestionAndAnswer() {
        addNote()
        navigate("Painel")
        search("UI question")
        activate(app.staticTexts["UI question"].firstMatch)
        activate(identified("browser.actions.menu"))
        menuButton("Pré-visualizar cartão", swipeDown: true)

        #if os(macOS)
        XCTAssertTrue(app.staticTexts["Pré-visualização"].waitForExistence(timeout: 10), app.debugDescription)
        #else
        XCTAssertTrue(app.navigationBars["Pré-visualização"].waitForExistence(timeout: 10), app.debugDescription)
        #endif
        XCTAssertTrue(app.webViews.staticTexts["UI question"].waitForExistence(timeout: 10), app.debugDescription)
        activate(identified("browser.preview.toggleAnswer"))
        XCTAssertTrue(app.webViews.staticTexts["UI answer"].waitForExistence(timeout: 10), app.debugDescription)
        activate(identified("browser.preview.toggleAnswer"))
        XCTAssertTrue(app.webViews.staticTexts["UI question"].waitForExistence(timeout: 10), app.debugDescription)
        activate(identified("browser.preview.close"))
        XCTAssertTrue(app.textFields["Busca (deck:, tag:, is:new…)"].exists, app.debugDescription)
    }

    func testBrowserInlineEditorSavesFieldChanges() {
        addNote()
        navigate("Painel")
        search("UI question")
        activate(app.staticTexts["UI question"].firstMatch)
        let htmlMode = app.buttons["browser.toggleRichEditor"].firstMatch
        XCTAssertTrue(htmlMode.waitForExistence(timeout: 5), app.debugDescription)
        #if os(macOS)
        let window = app.windows.firstMatch
        let windowOrigin = window.coordinate(withNormalizedOffset: .zero)
        let localY = htmlMode.frame.midY - window.frame.minY
        for _ in 0..<2 {
            let start = windowOrigin.withOffset(CGVector(dx: window.frame.width - 8, dy: localY))
            let end = windowOrigin.withOffset(CGVector(dx: 12, dy: localY))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        #else
        let appOrigin = app.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<2 {
            let start = appOrigin.withOffset(CGVector(dx: app.frame.maxX - 8, dy: htmlMode.frame.midY))
            let end = appOrigin.withOffset(CGVector(dx: app.frame.minX + 12, dy: htmlMode.frame.midY))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        #endif
        activate(htmlMode)

        let front = app.textViews["field.source.Front"].firstMatch
        XCTAssertTrue(front.waitForExistence(timeout: 10), app.debugDescription)
        front.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.12)).tap()
        type(" edited", into: front)
        XCTAssertEqual(front.value as? String, "UI question edited", app.debugDescription)
        let save = identified("browser.editor.save")
        let editorScroll = app.scrollViews.containing(.button, identifier: "browser.editor.save").firstMatch
        XCTAssertTrue(editorScroll.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<8 {
            if save.isHittable { break }
            editorScroll.swipeUp()
        }
        XCTAssertTrue(save.isHittable, app.debugDescription)
        activate(save)
        search("UI question edited")
        let updatedResult = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "UI question edited", "UI question edited")
        ).firstMatch
        XCTAssertTrue(updatedResult.waitForExistence(timeout: 10), app.debugDescription)
    }

    func testBrowserSelectSuspendAndUnsuspendMultipleCards() {
        addNote(front: "UI bulk first", back: "UI bulk answer first")
        addNote(front: "UI bulk second", back: "UI bulk answer second")
        navigate("Painel")
        search("UI bulk")

        activate(identified("browser.actions.menu"))
        activate(identified("browser.selectAll"))
        activate(identified("browser.actions.menu"))
        let suspendSelection = identified("browser.selection.suspend")
        XCTAssertTrue(suspendSelection.waitForExistence(timeout: 10), app.debugDescription)
        activate(suspendSelection)

        search("is:suspended")
        XCTAssertTrue(app.staticTexts["UI bulk first"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["UI bulk second"].exists, app.debugDescription)

        activate(identified("browser.actions.menu"))
        activate(identified("browser.selectAll"))
        activate(identified("browser.actions.menu"))
        XCTAssertTrue(suspendSelection.waitForExistence(timeout: 10), app.debugDescription)
        activate(suspendSelection)

        search("is:suspended")
        XCTAssertTrue(app.staticTexts["Nenhum cartão"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testBrowserChangeNoteTypePreservesFieldsAndUndo() {
        addNote(front: "UI type change front", back: "UI type change back")
        navigate("Baralhos")
        button("Mais ações dos baralhos")
        activate(identified("decks.noteTypes"))
        activate(identified("notetypes.action.Adicionar Basic (e invertido)"))
        let createdTypePredicate = NSPredicate(format: "label BEGINSWITH %@", "Basic (and reversed)")
        #if os(macOS)
        let createdType = app.buttons.matching(createdTypePredicate).firstMatch
        #else
        let createdType = app.staticTexts.containing(createdTypePredicate).firstMatch
        #endif
        XCTAssertTrue(createdType.waitForExistence(timeout: 10), app.debugDescription)
        #if os(macOS)
        let createdTypeName = createdType.label.components(separatedBy: ",").first ?? createdType.label
        #else
        let createdTypeName = createdType.label
        #endif
        let typeIdentifier = "browser.noteType.\(createdTypeName)"
        let typeSearch = "note:\"\(createdTypeName)\""

        navigate("Painel")
        search("UI type change front")
        let note = app.staticTexts["UI type change front"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), app.debugDescription)

        activate(identified("browser.actions.menu"))
        activate(identified("browser.selectAll"))
        activate(identified("browser.actions.menu"))
        activate(identified("browser.changeNoteType"))
        let typeChoice = identified(typeIdentifier)
        XCTAssertTrue(typeChoice.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(typeChoice.isHittable, app.debugDescription)
        activate(typeChoice)

        search(typeSearch)
        XCTAssertTrue(app.staticTexts["UI type change front"].waitForExistence(timeout: 10), app.debugDescription)
        search("UI type change back")
        #if os(macOS)
        XCTAssertTrue(app.staticTexts["UI type change front"].waitForExistence(timeout: 10), app.debugDescription)
        #else
        let convertedBack = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "UI type change back")
        ).firstMatch
        XCTAssertTrue(convertedBack.waitForExistence(timeout: 10), app.debugDescription)
        #endif

        button("Desfazer")
        search(typeSearch)
        XCTAssertTrue(app.staticTexts["Nenhum cartão"].waitForExistence(timeout: 10), app.debugDescription)
        search("note:Basic")
        XCTAssertTrue(app.staticTexts["UI type change front"].waitForExistence(timeout: 10), app.debugDescription)
        search("UI type change back")
        #if os(macOS)
        XCTAssertTrue(app.staticTexts["UI type change front"].waitForExistence(timeout: 10), app.debugDescription)
        #else
        let restoredBack = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "UI type change back")
        ).firstMatch
        XCTAssertTrue(restoredBack.waitForExistence(timeout: 10), app.debugDescription)
        #endif
    }

    func testSourceEditorPreservesTypedText() {
        navigate("Adicionar")
        if !app.textViews["field.source.Front"].firstMatch.exists { button("add.source") }
        let editor = app.textViews["field.source.Front"].firstMatch
        enter("UI type change front", into: editor)
        XCTAssertEqual(editor.value as? String, "UI type change front")
    }

    func testSourceEditorFormatsSelectedText() {
        navigate("Adicionar")
        if !app.textViews["field.source.Front"].firstMatch.exists { button("add.source") }
        let editor = app.textViews["field.source.Front"].firstMatch
        #if os(iOS)
        reveal(editor)
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).tap()
        type("abc", into: editor)
        XCTAssertEqual(editor.value as? String, "abc", app.debugDescription)
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.15)).doubleTap()
        #else
        enter("abc", into: editor)
        editor.typeKey("a", modifierFlags: .command)
        #endif
        let bold = app.buttons["B"].firstMatch
        func waitForSourceValue(_ expected: String) {
            let valueExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", expected),
                object: editor
            )
            XCTAssertEqual(XCTWaiter.wait(for: [valueExpectation], timeout: 5), .completed, app.debugDescription)
        }
        func applyFormatAction(_ title: String) {
            let action = app.buttons[title].firstMatch
            let bar = identified("field.formatBar.Front")
            XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
            #if os(iOS)
            XCTAssertTrue(bar.waitForExistence(timeout: 5), app.debugDescription)
            reveal(bar)
            for _ in 0..<12 {
                if action.isHittable { break }
                if action.frame.maxX < bar.frame.minX { bar.swipeRight() }
                else { bar.swipeLeft() }
            }
            XCTAssertTrue(action.isHittable, app.debugDescription)
            #else
            reveal(action)
            #endif
            activate(action)
        }
        XCTAssertTrue(bold.waitForExistence(timeout: 5), app.debugDescription)
        activate(bold)
        XCTAssertEqual(editor.value as? String, "<b>abc</b>", app.debugDescription)

        let italic = app.buttons["I"].firstMatch
        XCTAssertTrue(italic.waitForExistence(timeout: 5), app.debugDescription)
        activate(italic)
        XCTAssertEqual(editor.value as? String, "<b><i>abc</i></b>", app.debugDescription)

        let underline = app.buttons["U"].firstMatch
        XCTAssertTrue(underline.waitForExistence(timeout: 5), app.debugDescription)
        activate(underline)
        XCTAssertEqual(editor.value as? String, "<b><i><u>abc</u></i></b>", app.debugDescription)

        let larger = app.buttons["Aa"].firstMatch
        XCTAssertTrue(larger.waitForExistence(timeout: 5), app.debugDescription)
        activate(larger)
        XCTAssertEqual(
            editor.value as? String,
            "<b><i><u><span style=\"font-size:1.2em\">abc</span></u></i></b>",
            app.debugDescription
        )

        applyFormatAction("Fx")
        waitForSourceValue("abc")

        #if os(iOS)
        func clearSourceFormatting() {
            applyFormatAction("Fx")
            waitForSourceValue("abc")
        }

        applyFormatAction("Code")
        XCTAssertEqual(editor.value as? String, "<code>abc</code>", app.debugDescription)
        clearSourceFormatting()

        applyFormatAction("Sobrescrito")
        XCTAssertEqual(editor.value as? String, "<sup>abc</sup>", app.debugDescription)
        clearSourceFormatting()

        applyFormatAction("Subscrito")
        XCTAssertEqual(editor.value as? String, "<sub>abc</sub>", app.debugDescription)
        clearSourceFormatting()

        applyFormatAction("Lista com marcadores")
        XCTAssertEqual(editor.value as? String, "<ul><li>abc</li></ul>", app.debugDescription)
        clearSourceFormatting()

        applyFormatAction("Lista numerada")
        XCTAssertEqual(editor.value as? String, "<ol><li>abc</li></ol>", app.debugDescription)
        clearSourceFormatting()
        #endif
    }

    #if os(iOS)
    func testSourceEditorPartialSelectionAppliesFormattingToRange() {
        navigate("Adicionar")
        if !app.textViews["field.source.Front"].firstMatch.exists { button("add.source") }
        let editor = app.textViews["field.source.Front"].firstMatch
        reveal(editor)
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.15)).tap()
        editor.typeText("alpha beta")
        XCTAssertEqual(editor.value as? String, "alpha beta", app.debugDescription)

        for _ in 0..<4 {
            editor.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: .shift)
        }
        editor.typeText("X")
        XCTAssertEqual(editor.value as? String, "alpha X", app.debugDescription)

        editor.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: .shift)
        let hideKeyboard = app.buttons["Ocultar teclado"].firstMatch
        if hideKeyboard.exists { activate(hideKeyboard) }
        let superscript = app.buttons["Sobrescrito"].firstMatch
        let bar = identified("field.formatBar.Front")
        XCTAssertTrue(superscript.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(bar.waitForExistence(timeout: 5), app.debugDescription)
        reveal(bar)
        for _ in 0..<12 {
            if superscript.isHittable { break }
            if superscript.frame.maxX < bar.frame.minX { bar.swipeRight() }
            else { bar.swipeLeft() }
        }
        XCTAssertTrue(superscript.isHittable, app.debugDescription)
        activate(superscript)
        XCTAssertEqual(editor.value as? String, "alpha <sup>X</sup>", app.debugDescription)

        let clear = app.buttons["Fx"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5), app.debugDescription)
        reveal(bar)
        for _ in 0..<12 {
            if clear.isHittable { break }
            if clear.frame.maxX < bar.frame.minX { bar.swipeRight() }
            else { bar.swipeLeft() }
        }
        XCTAssertTrue(clear.isHittable, app.debugDescription)
        activate(clear)
        let plainText = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "alpha X"),
            object: editor
        )
        XCTAssertEqual(XCTWaiter.wait(for: [plainText], timeout: 5), .completed, app.debugDescription)
    }
    #endif

    func testEditorMediaPickerCanBeCancelled() {
        navigate("Adicionar")
        if !app.textViews["field.source.Front"].firstMatch.exists { button("add.source") }
        let attachMedia = app.buttons["field.addMedia.Front"].firstMatch
        XCTAssertTrue(attachMedia.waitForExistence(timeout: 10), app.debugDescription)
        activate(attachMedia)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.08)).tap()
        XCTAssertTrue(app.textViews["field.source.Front"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(identified("add.submit").exists, app.debugDescription)
    }

    #if os(iOS)
    func testEditorMediaPickerImportsImageFile() {
        func pixelCount(_ element: XCUIElement) -> String {
            String((element.value as? String ?? "").filter(\.isNumber))
        }

        func restoreImageLimit() {
            app.terminate()
            app.launch()
            finishTutorialIfPresented()
            navigate("Ferramentas")
            let savedImageLimit = identified("preferences.imageMaxDimension")
            if !savedImageLimit.waitForExistence(timeout: 1) {
                button("Preferências do AnkiOS")
            }
            XCTAssertTrue(savedImageLimit.waitForExistence(timeout: 10), app.debugDescription)
            revealPreferenceElement(savedImageLimit)
            let currentLimit = Int(pixelCount(savedImageLimit)) ?? 0
            let increaseLimit = savedImageLimit.buttons.element(boundBy: 1)
            let decreaseLimit = savedImageLimit.buttons.element(boundBy: 0)
            if currentLimit < 1024 {
                for _ in 0..<((1024 - currentLimit) / 128) { increaseLimit.tap() }
            } else if currentLimit > 1024 {
                for _ in 0..<((currentLimit - 1024) / 128) { decreaseLimit.tap() }
            }
            XCTAssertEqual(pixelCount(savedImageLimit), "1024", app.debugDescription)
            let resizePastedImages = identified("preferences.resizePastedImages")
            setToggle(resizePastedImages, to: false)
            activate(identified("preferences.save"))
        }

        func setPasteResize(_ enabled: Bool) {
            navigate("Ferramentas")
            let resizePastedImages = identified("preferences.resizePastedImages")
            if !resizePastedImages.waitForExistence(timeout: 1) {
                button("Preferências do AnkiOS")
            }
            XCTAssertTrue(resizePastedImages.waitForExistence(timeout: 10), app.debugDescription)
            revealPreferenceElement(resizePastedImages)
            XCTAssertTrue(resizePastedImages.isHittable, app.debugDescription)
            if toggleValue(resizePastedImages) != enabled {
                activate(resizePastedImages)
                let deadline = Date().addingTimeInterval(3)
                while Date() < deadline && toggleValue(resizePastedImages) != enabled {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                }
            }
            XCTAssertEqual(toggleValue(resizePastedImages), enabled, app.debugDescription)
            activate(identified("preferences.save"))
        }

        func addPastedImageNote(_ title: String) {
            navigate("Adicionar")
            let source = app.textViews["field.source.Front"].firstMatch
            if !source.exists { button("add.source") }
            let front = app.textViews["field.source.Front"].firstMatch
            XCTAssertTrue(front.waitForExistence(timeout: 10), app.debugDescription)
            enter(title, into: front)
            button("add.source")

            let editor = app.webViews.firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
            let editable = editor.textViews.firstMatch
            XCTAssertTrue(editable.waitForExistence(timeout: 10), app.debugDescription)
            editable.tap()
            editable.typeKey("v", modifierFlags: .command)

            button("add.source")
            let pastedReference = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value CONTAINS %@", "paste-"),
                object: app.textViews["field.source.Front"].firstMatch
            )
            XCTAssertEqual(XCTWaiter.wait(for: [pastedReference], timeout: 15), .completed, app.debugDescription)
            activate(identified("add.submit"))
            XCTAssertTrue(app.staticTexts["Nota adicionada."].waitForExistence(timeout: 10), app.debugDescription)
            finishTutorialIfPresented()
        }

        if Bundle(for: Self.self).object(forInfoDictionaryKey: "ANKIOS_UI_CAMERA_AVAILABILITY_ONLY") as? String == "1" {
            navigate("Adicionar")
            if !app.textViews["field.source.Front"].firstMatch.exists { button("add.source") }
            activate(identified("field.addMedia.Front"))
            XCTAssertFalse(identified("noteField.fromCamera").exists, app.debugDescription)
            return
        }

        if UIDevice.current.userInterfaceIdiom == .pad {
            navigate("Adicionar")
            if !app.textViews["field.source.Front"].firstMatch.exists { button("add.source") }
            let front = app.textViews["field.source.Front"].firstMatch
            enter("UI iPad drawing", into: front)
            activate(app.buttons["field.addMedia.Front"].firstMatch)
            let draw = identified("noteField.draw")
            XCTAssertTrue(draw.waitForExistence(timeout: 10), app.debugDescription)
            activate(draw)

            let canvas = identified("noteDrawing.canvas")
            XCTAssertTrue(canvas.waitForExistence(timeout: 10), app.debugDescription)
            let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.45))
            let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.55))
            start.press(forDuration: 0.05, thenDragTo: end)
            activate(identified("noteDrawing.save"))

            let insertedDrawing = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value CONTAINS %@", "drawing-"),
                object: front
            )
            XCTAssertEqual(XCTWaiter.wait(for: [insertedDrawing], timeout: 10), .completed, app.debugDescription)
            activate(identified("add.submit"))
            XCTAssertTrue(app.staticTexts["Nota adicionada."].waitForExistence(timeout: 10), app.debugDescription)
            finishTutorialIfPresented()

            let drawingNote = app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", "UI iPad drawing")
            ).firstMatch
            reveal(drawingNote)
            activate(drawingNote)
            XCTAssertTrue(identified("noteEditor.save").waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(drawingNote.label.contains("drawing-"), drawingNote.label)
            let drawingField = app.webViews.firstMatch
            XCTAssertTrue(drawingField.exists, app.debugDescription)
            drawingField.pinch(withScale: 1.05, velocity: 0.05)
            XCTAssertTrue(identified("noteDrawing.canvas").waitForExistence(timeout: 10), app.debugDescription)
            activate(identified("noteDrawing.save"))
            return
        }

        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let imageLimit = identified("preferences.imageMaxDimension")
        XCTAssertTrue(imageLimit.waitForExistence(timeout: 10), app.debugDescription)
        revealPreferenceElement(imageLimit)
        let decreaseImageLimit = imageLimit.buttons.element(boundBy: 0)
        let increaseImageLimit = imageLimit.buttons.element(boundBy: 1)
        let currentImageLimit = Int(pixelCount(imageLimit)) ?? 0
        XCTAssertGreaterThanOrEqual(currentImageLimit, 512, app.debugDescription)
        if currentImageLimit > 512 {
            for _ in 0..<((currentImageLimit - 512) / 128) { decreaseImageLimit.tap() }
        } else if currentImageLimit < 512 {
            for _ in 0..<((512 - currentImageLimit) / 128) { increaseImageLimit.tap() }
        }
        XCTAssertEqual(pixelCount(imageLimit), "512", app.debugDescription)
        activate(identified("preferences.save"))

        navigate("Adicionar")
        if !app.textViews["field.source.Front"].firstMatch.exists { button("add.source") }
        let front = app.textViews["field.source.Front"].firstMatch
        enter("UI image", into: front)

        let attachMedia = app.buttons["field.addMedia.Front"].firstMatch
        activate(attachMedia)
#if targetEnvironment(simulator)
        XCTAssertFalse(identified("noteField.fromCamera").exists, app.debugDescription)
#endif
#if !targetEnvironment(simulator)
        let fromCamera = identified("noteField.fromCamera")
        XCTAssertTrue(fromCamera.waitForExistence(timeout: 10), app.debugDescription)
        if fromCamera.waitForExistence(timeout: 1) {
            activate(fromCamera)
            let cameraPermission = app.alerts.buttons.matching(
                NSPredicate(format: "label IN %@", ["Permitir", "Allow"])
            ).firstMatch
            if cameraPermission.waitForExistence(timeout: 3) { activate(cameraPermission) }

            let shutter = app.buttons.matching(
                NSPredicate(format: "label IN %@", ["Tirar Foto", "Tirar uma foto", "Take Picture", "Take Photo"])
            ).firstMatch
            XCTAssertTrue(shutter.waitForExistence(timeout: 15), app.debugDescription)
            activate(shutter)
            let usePhoto = app.buttons.matching(
                NSPredicate(format: "label IN %@", ["Usar Foto", "Use Photo"])
            ).firstMatch
            XCTAssertTrue(usePhoto.waitForExistence(timeout: 15), app.debugDescription)
            activate(usePhoto)

            let importedCameraPhoto = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value CONTAINS[c] %@ AND value CONTAINS[c] %@", "photo-", ".jpg"),
                object: front
            )
            XCTAssertEqual(XCTWaiter.wait(for: [importedCameraPhoto], timeout: 15), .completed, app.debugDescription)
            activate(identified("add.submit"))
            XCTAssertTrue(app.staticTexts["Nota adicionada."].waitForExistence(timeout: 10), app.debugDescription)
            finishTutorialIfPresented()
            restoreImageLimit()
            return
        }
#endif

        let fromPhotos = app.buttons["photo"].firstMatch
        XCTAssertTrue(fromPhotos.waitForExistence(timeout: 10), app.debugDescription)
        activate(fromPhotos)
        let photo = app.images.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "Foto,")
        ).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), app.debugDescription)
        activate(photo)
        let importedPhoto = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS[c] %@ AND value CONTAINS[c] %@", "photo-", ".jpg"),
            object: front
        )
        XCTAssertEqual(XCTWaiter.wait(for: [importedPhoto], timeout: 15), .completed, app.debugDescription)

        activate(attachMedia)
        let fromFile = app.buttons["folder"].firstMatch
        XCTAssertTrue(fromFile.waitForExistence(timeout: 10), app.debugDescription)
        activate(fromFile)

        let fixture = app.cells.matching(
            NSPredicate(format: "identifier CONTAINS[c] %@", "ankios-picker-fixture")
        ).firstMatch
        if !fixture.waitForExistence(timeout: 8) {
            let browse = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Explorar")
            ).firstMatch
            if browse.exists { activate(browse) }
            let downloads = app.cells.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Downloads")
            ).firstMatch
            XCTAssertTrue(downloads.waitForExistence(timeout: 10), app.debugDescription)
            activate(downloads)
        }
        XCTAssertTrue(fixture.waitForExistence(timeout: 15), app.debugDescription)
        activate(fixture)

        let importedReference = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "ankios-picker-fixture.png"),
            object: front
        )
        XCTAssertEqual(XCTWaiter.wait(for: [importedReference], timeout: 10), .completed, app.debugDescription)
        XCTAssertTrue((front.value as? String)?.contains("<img") == true, app.debugDescription)

        let submit = identified("add.submit")
        XCTAssertTrue(submit.exists, app.debugDescription)
        activate(submit)
        XCTAssertTrue(app.staticTexts["Nota adicionada."].waitForExistence(timeout: 10), app.debugDescription)
        finishTutorialIfPresented()

        let imageFormat = UIGraphicsImageRendererFormat()
        imageFormat.scale = 1
        let clipboardImage = UIGraphicsImageRenderer(
            size: CGSize(width: 2048, height: 1024),
            format: imageFormat
        ).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1024))
        }
        guard let clipboardImageData = clipboardImage.pngData() else {
            XCTFail("Não foi possível criar a imagem de teste")
            return
        }
        UIPasteboard.general.setItems([[
            "public.png": clipboardImageData,
            "public.image": clipboardImageData
        ]])
        setPasteResize(true)
        addPastedImageNote("UI pasted resized")

        setPasteResize(false)
        UIPasteboard.general.setItems([[
            "public.png": clipboardImageData,
            "public.image": clipboardImageData
        ]])
        addPastedImageNote("UI pasted original")

        restoreImageLimit()
    }

    func testNoteEditorImportsAndPersistsMedia() async throws {
        navigate("Adicionar")
        if !app.textViews["field.source.Front"].firstMatch.exists { button("add.source") }
        enter("UI media edit", into: app.textViews["field.source.Front"].firstMatch)
        button("add.submit")
        XCTAssertTrue(app.staticTexts["Nota adicionada."].waitForExistence(timeout: 10), app.debugDescription)
        finishTutorialIfPresented()

        let historyItem = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "UI media edit")
        ).firstMatch
        reveal(historyItem)
        activate(historyItem)
        let front = app.textViews["field.source.Front"].firstMatch
        XCTAssertTrue(front.waitForExistence(timeout: 10), app.debugDescription)

        let attachMedia = app.buttons["field.addMedia.Front"].firstMatch
        func selectFixture(_ name: String) {
            activate(attachMedia)
            let fromFile = app.buttons["folder"].firstMatch
            XCTAssertTrue(fromFile.waitForExistence(timeout: 10), app.debugDescription)
            activate(fromFile)
            let fixture = app.cells.matching(
                NSPredicate(format: "identifier CONTAINS[c] %@", name)
            ).firstMatch
            if !fixture.waitForExistence(timeout: 8) {
                let browse = app.buttons.matching(
                    NSPredicate(format: "label CONTAINS[c] %@", "Explorar")
                ).firstMatch
                if browse.exists { activate(browse) }
                let downloads = app.cells.matching(
                    NSPredicate(format: "label CONTAINS[c] %@", "Downloads")
                ).firstMatch
                XCTAssertTrue(downloads.waitForExistence(timeout: 10), app.debugDescription)
                activate(downloads)
            }
            XCTAssertTrue(fixture.waitForExistence(timeout: 15), app.debugDescription)
            activate(fixture)
        }
        selectFixture("ankios-picker-fixture")
        selectFixture("ankios-picker-audio-fixture")
        selectFixture("ankios-picker-video-fixture")

        let editHTML = app.buttons["Editar HTML"].firstMatch
        reveal(editHTML)
        activate(editHTML)
        let frontSource = app.textViews["field.source.Front"].firstMatch
        XCTAssertTrue(frontSource.waitForExistence(timeout: 10), app.debugDescription)
        let importedHTML = frontSource.value as? String ?? ""
        XCTAssertTrue(importedHTML.contains("ankios-picker-fixture.png"), importedHTML)
        XCTAssertTrue(importedHTML.contains("[sound:ankios-picker-audio-fixture.wav]"), importedHTML)
        XCTAssertTrue(importedHTML.localizedCaseInsensitiveContains("<video"), importedHTML)
        XCTAssertTrue(importedHTML.contains("ankios-picker-video-fixture.mp4"), importedHTML)
        activate(identified("noteEditor.save"))

        XCTAssertTrue(historyItem.waitForExistence(timeout: 10), app.debugDescription)
        activate(historyItem)
        let reopenHTML = app.buttons["Editar HTML"].firstMatch
        reveal(reopenHTML)
        activate(reopenHTML)
        let reopenedFrontSource = app.textViews["field.source.Front"].firstMatch
        XCTAssertTrue(reopenedFrontSource.waitForExistence(timeout: 10), app.debugDescription)
        let savedHTML = reopenedFrontSource.value as? String ?? ""
        XCTAssertTrue(savedHTML.contains("ankios-picker-fixture.png"), savedHTML)
        XCTAssertTrue(savedHTML.contains("[sound:ankios-picker-audio-fixture.wav]"), savedHTML)
        XCTAssertTrue(savedHTML.localizedCaseInsensitiveContains("<video"), savedHTML)
        XCTAssertTrue(savedHTML.contains("ankios-picker-video-fixture.mp4"), savedHTML)
        activate(identified("noteEditor.close"))

        navigate("Painel")
        search("UI media edit")
        let mediaCard = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "UI media edit")
        ).firstMatch
        activate(mediaCard)
        activate(identified("browser.actions.menu"))
        menuButton("Pré-visualizar cartão", swipeDown: true)
        let preview = app.webViews.firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(preview.images.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        let playVideo = app.buttons["Reproduzir"].firstMatch
        XCTAssertTrue(playVideo.waitForExistence(timeout: 10), app.debugDescription)
        activate(playVideo)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        assertImagePixel(
            at: CGPoint(x: 10, y: 370),
            redDominant: false,
            message: "A reprodução deve mostrar o quadro azul do vídeo importado."
        )

        app.terminate()
        app.launch()
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"].firstMatch)
        button("Estudar agora")
        let studyCard = app.webViews.staticTexts["UI media edit"].firstMatch
        XCTAssertTrue(studyCard.waitForExistence(timeout: 15), app.debugDescription)
        let studyWebView = app.webViews.firstMatch
        let studyPlayVideo = app.buttons["Reproduzir"].firstMatch
        for _ in 0..<8 {
            if studyPlayVideo.isHittable { break }
            studyWebView.swipeUp()
        }
        XCTAssertTrue(studyPlayVideo.isHittable, app.debugDescription)
        activate(studyPlayVideo)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        assertImageContainsBlueFrame(message: "O cartão em estudo deve reproduzir o quadro azul do vídeo importado.")
    }

    func testAddClozeWithoutDeletionCanBeCancelledOrConfirmed() {
        navigate("Baralhos")
        button("Mais ações dos baralhos")
        activate(identified("decks.noteTypes"))
        activate(identified("notetypes.action.Adicionar tipo Cloze"))
        navigate("Adicionar")

        let basicType = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Basic")
        ).firstMatch
        XCTAssertTrue(basicType.waitForExistence(timeout: 10), app.debugDescription)
        activate(basicType)
        let clozeType = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Cloze")
        ).firstMatch
        XCTAssertTrue(clozeType.waitForExistence(timeout: 10), app.debugDescription)
        activate(clozeType)

        if !app.textViews["field.source.Text"].firstMatch.exists { button("add.source") }
        let text = app.textViews["field.source.Text"].firstMatch
        enter("UI missing cloze", into: text)
        let submit = identified("add.submit")
        XCTAssertTrue(submit.exists, app.debugDescription)
        activate(submit)

        let warning = app.alerts["Nota Cloze sem omissões"]
        XCTAssertTrue(warning.waitForExistence(timeout: 10), app.debugDescription)
        button("Cancelar")
        XCTAssertEqual(text.value as? String, "UI missing cloze", app.debugDescription)
        XCTAssertFalse(app.staticTexts["Nota adicionada."].exists, app.debugDescription)

        activate(submit)
        XCTAssertTrue(warning.waitForExistence(timeout: 10), app.debugDescription)
        button("Adicionar mesmo assim")
        XCTAssertTrue(app.staticTexts["Nota adicionada."].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "UI missing cloze"))
                .firstMatch.waitForExistence(timeout: 10),
            app.debugDescription
        )
    }

    func testAddNoteRecordsAudioIntoField() async throws {
        navigate("Adicionar")
        if !app.textViews["field.source.Front"].firstMatch.exists { button("add.source") }
        let front = app.textViews["field.source.Front"].firstMatch
        enter("UI audio", into: front)

        let addMedia = identified("field.addMedia.Front")
        activate(addMedia)
        let startRecording = identified("noteField.recordVoice")
        XCTAssertTrue(startRecording.waitForExistence(timeout: 10), app.debugDescription)
        reveal(startRecording)
        activate(startRecording)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let microphonePermission = springboard.alerts.firstMatch
        if microphonePermission.waitForExistence(timeout: 3) {
            let allowMicrophone = microphonePermission.buttons.matching(
                NSPredicate(
                    format: "(label CONTAINS[c] %@ OR label CONTAINS[c] %@) AND NOT (label CONTAINS[c] %@ OR label CONTAINS[c] %@)",
                    "Allow", "Permitir", "Don't", "Não"
                )
            ).firstMatch
            if allowMicrophone.exists { allowMicrophone.tap() }
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        activate(addMedia)
        let stopRecording = identified("noteField.recordVoice")
        XCTAssertTrue(stopRecording.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(stopRecording.label.localizedCaseInsensitiveContains("Parar") || stopRecording.label.localizedCaseInsensitiveContains("Stop"), app.debugDescription)
        activate(stopRecording)

        let audioReference = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "[sound:ankios-recording-"),
            object: front
        )
        XCTAssertEqual(XCTWaiter.wait(for: [audioReference], timeout: 10), .completed, app.debugDescription)
        let html = front.value as? String ?? ""
        XCTAssertTrue(html.hasSuffix(".m4a]"), app.debugDescription)

        button("add.submit")
        XCTAssertTrue(app.staticTexts["Nota adicionada."].waitForExistence(timeout: 10), app.debugDescription)
        let savedNote = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "UI audio")).firstMatch
        XCTAssertTrue(savedNote.waitForExistence(timeout: 10), app.debugDescription)
    }
    #endif

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

#if os(iOS)
    func testAnkiWebForcedFullSyncPromptCanBeCancelled() throws {
        let endpoint = Bundle(for: Self.self).object(forInfoDictionaryKey: "ANKIOS_UI_SYNC_ENDPOINT") as? String
            ?? ProcessInfo.processInfo.environment["ANKIOS_UI_SYNC_ENDPOINT"]
        guard let endpoint,
              URL(string: endpoint)?.host == "127.0.0.1" else {
            throw XCTSkip("Defina ANKIOS_UI_SYNC_ENDPOINT para um servidor Anki descartável em localhost")
        }

        navigate("Ferramentas")
        button("Preferências do AnkiOS")
        let forceChoice = identified("preferences.Na próxima sincronização, escolher enviar ou baixar")
        reveal(forceChoice)
        if toggleValue(forceChoice) != true {
            activate(forceChoice)
        }
        let toggleDeadline = Date().addingTimeInterval(3)
        while Date() < toggleDeadline && toggleValue(forceChoice) != true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(toggleValue(forceChoice), true, "Switch não foi ligado; frame: \(forceChoice.frame)")
        activate(identified("preferences.save"))
        activate(app.navigationBars.buttons.element(boundBy: 0))

        button("Preferências do AnkiOS")
        let savedForceChoice = identified("preferences.Na próxima sincronização, escolher enviar ou baixar")
        reveal(savedForceChoice)
        XCTAssertEqual(toggleValue(savedForceChoice), true, app.debugDescription)
        activate(app.navigationBars.buttons.element(boundBy: 0))

        loginToLocalSync()
        let upload = identified("ankiweb.fullSync.upload")
        let download = identified("ankiweb.fullSync.download")
        XCTAssertTrue(upload.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(download.waitForExistence(timeout: 10), app.debugDescription)
        let promptTitle = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Sincronização completa necessária")
        ).firstMatch
        XCTAssertTrue(promptTitle.exists, app.debugDescription)

        let cancel = identified("ankiweb.fullSync.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        activate(cancel)
        button("Sincronizar agora")
        XCTAssertTrue(download.waitForExistence(timeout: 10), app.debugDescription)
        activate(cancel)
    }
#endif

    func testLocalSyncLoginUploadIncrementalDownloadAndDisconnect() throws {
        let endpoint = Bundle(for: Self.self).object(forInfoDictionaryKey: "ANKIOS_UI_SYNC_ENDPOINT") as? String
            ?? ProcessInfo.processInfo.environment["ANKIOS_UI_SYNC_ENDPOINT"]
        guard let endpoint,
              URL(string: endpoint)?.host == "127.0.0.1" else {
            throw XCTSkip("Defina ANKIOS_UI_SYNC_ENDPOINT para um servidor Anki descartável em localhost")
        }
        let package = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "official", withExtension: "apkg"))
        app.open(package)
        activate(identified("packageImport.confirm"))
        finishTutorialIfPresented()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 30))
        button("OK")
        finishTutorialIfPresented()
        addNote(front: "UI synced question", back: "UI synced answer")
        navigate("Ferramentas")
        loginToLocalSync()
        let uploadCollection = identified("ankiweb.fullSync.upload")
        XCTAssertTrue(uploadCollection.waitForExistence(timeout: 30))
        activate(uploadCollection)
        assertAnkiWebStatus("Coleção enviada ao AnkiWeb.")
        addNote(front: "UI incremental question", back: "UI incremental answer")
        navigate("Ferramentas")
        button("Sincronizar agora")
        XCTAssertTrue(app.staticTexts["Sincronização com AnkiWeb concluída."].waitForExistence(timeout: 60))
        activate(app.navigationBars.buttons.element(boundBy: 0))
        activate(identified("settings.section.profiles"))
        button("Novo perfil…")
        enter("UI Download", into: app.alerts.textFields["Nome"].firstMatch)
        button("Criar")
        let activeProfile = identified("profiles.activeProfile")
        XCTAssertTrue(activeProfile.waitForExistence(timeout: 15))
        XCTAssertEqual(activeProfile.label, "UI Download")
        #if os(macOS)
        app.typeKey("[", modifierFlags: .command)
        #else
        activate(app.navigationBars.buttons.element(boundBy: 0))
        #endif
        let conflictingPackage = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "official-conflict", withExtension: "apkg"))
        app.open(conflictingPackage)
        activate(identified("packageImport.confirm"))
        finishTutorialIfPresented()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 30))
        button("OK")
        finishTutorialIfPresented()
        navigate("Ferramentas")
        loginToLocalSync()
        let downloadCollection = identified("ankiweb.fullSync.download")
        XCTAssertTrue(downloadCollection.waitForExistence(timeout: 30))
        activate(downloadCollection)
        assertAnkiWebStatus("Coleção baixada do AnkiWeb.")
        navigate("Painel")
        search("UI incremental question")
        XCTAssertTrue(app.staticTexts["UI incremental question"].firstMatch.waitForExistence(timeout: 10))
        navigate("Baralhos")
        activate(app.buttons["deck.open.UI Imported"])
        button("Estudar agora")
        button("Mostrar resposta")
        XCTAssertTrue(app.webViews.images.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.webViews.buttons["Reproduzir áudio"].firstMatch.waitForExistence(timeout: 10))
        #if os(iOS)
        let syncedImages = app.webViews.images.allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(syncedImages.count, 2, app.debugDescription)
        XCTAssertTrue(syncedImages.contains { $0.frame.width > 100 && $0.frame.height > 100 }, app.debugDescription)
        #endif
        activate(identified("study.close"))
        activate(identified("deck.overview.close"))
        navigate("Ferramentas")
        button("AnkiWeb")
        XCTAssertTrue(
            identified("ankiweb.account.username").waitForExistence(timeout: 10),
            app.debugDescription
        )
        XCTAssertEqual(identified("ankiweb.account.username").label, "ui-local", app.debugDescription)
        button("Desconectar conta")
        let openLoginPanel = identified("ankiweb.openLoginPanel")
        XCTAssertTrue(openLoginPanel.waitForExistence(timeout: 10), app.debugDescription)
        activate(openLoginPanel)
        XCTAssertTrue(identified("ankiweb.username").waitForExistence(timeout: 10), app.debugDescription)
    }

    func testLocalSyncMediaCancellationCanResume() throws {
        let endpoint = Bundle(for: Self.self).object(forInfoDictionaryKey: "ANKIOS_UI_SYNC_CANCEL_ENDPOINT") as? String
            ?? ProcessInfo.processInfo.environment["ANKIOS_UI_SYNC_CANCEL_ENDPOINT"]
        guard let endpoint,
              URL(string: endpoint)?.host == "127.0.0.1" else {
            throw XCTSkip("Defina ANKIOS_UI_SYNC_CANCEL_ENDPOINT para o proxy de sync limitado em localhost")
        }
        let package = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "official", withExtension: "apkg"))
        app.open(package)
        activate(identified("packageImport.confirm"))
        finishTutorialIfPresented()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 30))
        button("OK")
        finishTutorialIfPresented()
        navigate("Ferramentas")
        loginToLocalSync()
        let uploadCollection = identified("ankiweb.fullSync.upload")
        XCTAssertTrue(uploadCollection.waitForExistence(timeout: 30))
        activate(uploadCollection)
        XCTAssertTrue(app.staticTexts["Sincronizando mídia…"].waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Verificado:")).firstMatch.exists,
            app.debugDescription
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Adicionado:")).firstMatch.exists,
            app.debugDescription
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Removido:")).firstMatch.exists,
            app.debugDescription
        )
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Checked:")).firstMatch.exists,
            app.debugDescription
        )
        button("Cancelar sincronização")
        assertAnkiWebStatus("Sincronização cancelada.")
        button("Sincronizar agora")
        XCTAssertTrue(app.staticTexts["Sincronização com AnkiWeb concluída."].waitForExistence(timeout: 90), app.debugDescription)
        activate(app.navigationBars.buttons.element(boundBy: 0))
        activate(identified("settings.section.profiles"))
        button("Novo perfil…")
        enter("UI Media Resume", into: app.alerts.textFields["Nome"].firstMatch)
        button("Criar")
        let activeProfile = identified("profiles.activeProfile")
        XCTAssertTrue(activeProfile.waitForExistence(timeout: 15))
        XCTAssertEqual(activeProfile.label, "UI Media Resume")
        #if os(macOS)
        app.typeKey("[", modifierFlags: .command)
        #else
        activate(app.navigationBars.buttons.element(boundBy: 0))
        #endif
        let conflictingPackage = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "official-conflict", withExtension: "apkg"))
        app.open(conflictingPackage)
        activate(identified("packageImport.confirm"))
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 30))
        button("OK")
        finishTutorialIfPresented()
        navigate("Ferramentas")
        loginToLocalSync()
        let downloadCollection = identified("ankiweb.fullSync.download")
        guard downloadCollection.waitForExistence(timeout: 30) else {
            let uploadCollectionExists = identified("ankiweb.fullSync.upload").exists
            let visibleButtons = app.buttons.allElementsBoundByIndex.map(\.label)
            let visibleStatus = app.staticTexts.allElementsBoundByIndex.map(\.label)
                .filter { $0.contains("AnkiWeb") || $0.contains("sincroniza") || $0.contains("Sincroniza") }
            XCTFail(
                "Baixar coleção não apareceu. Enviar visível: \(uploadCollectionExists); status: \(visibleStatus); botões: \(visibleButtons)"
            )
            return
        }
        activate(downloadCollection)
        assertAnkiWebStatus("Coleção baixada do AnkiWeb.")
        navigate("Baralhos")
        activate(app.buttons["deck.open.UI Imported"])
        button("Estudar agora")
        button("Mostrar resposta")
        XCTAssertTrue(app.webViews.images.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.webViews.buttons["Reproduzir áudio"].firstMatch.waitForExistence(timeout: 10))
        #if os(iOS)
        let syncedImages = app.webViews.images.allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(syncedImages.count, 2, app.debugDescription)
        XCTAssertTrue(syncedImages.contains { $0.frame.width > 100 && $0.frame.height > 100 }, app.debugDescription)
        #endif
    }

    private func loginToLocalSync() {
        let openLoginPanel = identified("ankiweb.openLoginPanel")
        XCTAssertTrue(openLoginPanel.waitForExistence(timeout: 10), app.debugDescription)
        activate(openLoginPanel)
        enter("ui-local", into: identified("ankiweb.username"))
        enter("ui-local-only", into: identified("ankiweb.password"))
        let connect = identified("ankiweb.connect")
        XCTAssertTrue(connect.waitForExistence(timeout: 10), app.debugDescription)
        reveal(connect)
        activate(connect)
        let firstSyncChoice = app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR identifier == %@", "ankiweb.fullSync.upload", "ankiweb.fullSync.download")
        ).firstMatch
        XCTAssertTrue(firstSyncChoice.waitForExistence(timeout: 30), app.debugDescription)
    }

    private func assertAnkiWebStatus(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let status = app.staticTexts[expected]
        guard !status.waitForExistence(timeout: 60) else { return }
        let alert = app.alerts["Error"]
        if alert.waitForExistence(timeout: 2) {
            let detail = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
            XCTFail("Sync AnkiWeb falhou: \(detail)", file: file, line: line)
            return
        }
        let progress = app.staticTexts["Enviando coleção ao AnkiWeb…"]
        let state = progress.exists ? progress.label : app.debugDescription
        XCTFail("Sync AnkiWeb não concluiu. Estado: \(state)", file: file, line: line)
    }

    #if os(iOS)
    private func assertImagePixel(_ image: XCUIElement, redDominant: Bool, message: String = "O pixel não corresponde ao estado esperado.") {
        XCTAssertTrue(
            imagePixelMatches(at: CGPoint(x: image.frame.midX, y: image.frame.midY), redDominant: redDominant),
            message
        )
    }

    private func assertImagePixel(at point: CGPoint, redDominant: Bool, message: String = "O pixel não corresponde ao estado esperado.") {
        XCTAssertTrue(imagePixelMatches(at: point, redDominant: redDominant), message)
    }

    private func imagePixelMatches(at point: CGPoint, redDominant: Bool) -> Bool {
        let screenshot = app.screenshot().image
        guard let cgImage = screenshot.cgImage else {
            XCTFail("A captura de tela não contém pixels decodificáveis.")
            return false
        }
        let scaleX = CGFloat(cgImage.width) / app.frame.width
        let scaleY = CGFloat(cgImage.height) / app.frame.height
        let x = Int((point.x - app.frame.minX) * scaleX)
        let y = cgImage.height - Int((point.y - app.frame.minY) * scaleY)
        guard x >= 0, x < cgImage.width, y > 0, y <= cgImage.height else {
            XCTFail("A mídia está fora dos limites da captura.")
            return false
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext()
        pixel.withUnsafeMutableBytes { buffer in
            context.render(
                CIImage(cgImage: cgImage),
                toBitmap: buffer.baseAddress!,
                rowBytes: 4,
                bounds: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        }
        return redDominant
            ? Int(pixel[0]) > Int(pixel[2]) * 4
            : Int(pixel[2]) > Int(pixel[0]) * 4
    }

    private func assertImageContainsBlueFrame(message: String) {
        let screenshot = app.screenshot().image
        guard let cgImage = screenshot.cgImage else {
            XCTFail("A captura de tela não contém pixels decodificáveis.")
            return
        }
        let width = cgImage.width
        let height = cgImage.height
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        pixels.withUnsafeMutableBytes { buffer in
            CIContext().render(
                CIImage(cgImage: cgImage),
                toBitmap: buffer.baseAddress!,
                rowBytes: rowBytes,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        }
        var bluePixels = 0
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let offset = y * rowBytes + x * 4
                if pixels[offset] < 32 && pixels[offset + 1] < 32 && pixels[offset + 2] > 200 {
                    bluePixels += 1
                    if bluePixels >= 100 { break }
                }
            }
            if bluePixels >= 100 { break }
        }
        XCTAssertGreaterThanOrEqual(bluePixels, 100, message)
    }
    #endif

    func testOpenOfficialPackageAndStudyImportedMedia() throws {
        let fixtureURLString = Bundle(for: Self.self).object(forInfoDictionaryKey: "ANKIOS_UI_SHARED_DECK_FIXTURE_URL") as? String
        let fixtureURL = try XCTUnwrap(fixtureURLString.flatMap(URL.init(string:)))
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.open(fixtureURL)
        let downloadLink = safari.webViews.links["Download shared deck"].firstMatch
        XCTAssertTrue(downloadLink.waitForExistence(timeout: 15), safari.debugDescription)
        activate(downloadLink)
        let downloadConfirmation = safari.descendants(matching: .any).matching(identifier: "SFDialogView").firstMatch
        if downloadConfirmation.waitForExistence(timeout: 5) {
            downloadConfirmation.coordinate(withNormalizedOffset: CGVector(dx: 0.89, dy: 0.81)).tap()
        }
        safari.coordinate(withNormalizedOffset: CGVector(dx: 0.255, dy: 0.95)).tap()
        let downloadsButton = safari.buttons["Downloads"].firstMatch
        XCTAssertTrue(downloadsButton.waitForExistence(timeout: 10), safari.debugDescription)
        activate(downloadsButton)
        let downloadedPackage = safari.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Hiragana_and_Katakana.apkg")
        ).firstMatch
        XCTAssertTrue(downloadedPackage.waitForExistence(timeout: 15), safari.debugDescription)
        activate(downloadedPackage)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), safari.debugDescription)
        let importButton = identified("packageImport.confirm")
        XCTAssertTrue(importButton.waitForExistence(timeout: 20), app.debugDescription)
        activate(importButton)
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
        XCTAssertTrue(app.webViews.buttons["Reproduzir áudio"].firstMatch.waitForExistence(timeout: 10))
    }

    func testImportedImageOcclusionRendersQuestionAndAnswer() async throws {
        let package = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "occlusion", withExtension: "apkg"))
        app.open(package)
        button("Importar")
        if app.buttons["Importar"].firstMatch.waitForExistence(timeout: 5) {
            button("Importar")
        }
        finishTutorialIfPresented()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        button("OK")
        finishTutorialIfPresented()
        activate(app.buttons["deck.open.UI Occlusion"])
        button("Estudar agora")

        XCTAssertTrue(app.webViews.staticTexts["UI occlusion header"].waitForExistence(timeout: 15), app.debugDescription)
        let questionImage = app.webViews.images.firstMatch
        XCTAssertTrue(questionImage.waitForExistence(timeout: 15), app.debugDescription)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #if os(iOS)
        assertImagePixel(questionImage, redDominant: true, message: "A máscara precisa cobrir a imagem na pergunta.")
        #endif
        let questionScreenshot = XCTAttachment(screenshot: app.screenshot())
        questionScreenshot.name = "Oclusão - pergunta"
        questionScreenshot.lifetime = .keepAlways
        add(questionScreenshot)

        activate(identified("study.revealAnswer"))
        XCTAssertTrue(app.webViews.staticTexts["UI occlusion answer"].waitForExistence(timeout: 15), app.debugDescription)
        let answerImage = app.webViews.images.firstMatch
        XCTAssertTrue(answerImage.exists, app.debugDescription)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #if os(iOS)
        assertImagePixel(answerImage, redDominant: false, message: "A resposta deve revelar a imagem sob a máscara.")
        #endif
        let answerScreenshot = XCTAttachment(screenshot: app.screenshot())
        answerScreenshot.name = "Oclusão - resposta"
        answerScreenshot.lifetime = .keepAlways
        add(answerScreenshot)
    }

    func testImportedImageOcclusionMaskCanBeEditedAndSaved() throws {
        let package = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "occlusion", withExtension: "apkg"))
        app.open(package)
        button("Importar")
        if app.buttons["Importar"].firstMatch.waitForExistence(timeout: 5) {
            button("Importar")
        }
        finishTutorialIfPresented()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        button("OK")
        finishTutorialIfPresented()
        activate(app.buttons["deck.open.UI Occlusion"])
        button("Estudar agora")
        activate(identified("study.revealAnswer"))
        activate(identified("study.action.Editar"))
        let editMasks = identified("imageOcclusion.editMasks")
        XCTAssertTrue(editMasks.waitForExistence(timeout: 5), app.debugDescription)
        activate(editMasks)

        let shape = identified("imageOcclusion.shape")
        XCTAssertTrue(shape.waitForExistence(timeout: 10), app.debugDescription)
        activate(shape.buttons["Elipse"])
        let firstMask = app.staticTexts["Máscara 1"].firstMatch
        XCTAssertTrue(firstMask.waitForExistence(timeout: 10), app.debugDescription)
        let canvas = identified("imageOcclusion.canvas")
        reveal(canvas)
        XCTAssertTrue(canvas.isHittable, app.debugDescription)
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.75))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.staticTexts["Máscara 2"].waitForExistence(timeout: 10), app.debugDescription)

        activate(identified("imageOcclusion.save"))
        activate(identified("imageOcclusion.editMasks"))
        XCTAssertTrue(app.staticTexts["Máscara 2"].waitForExistence(timeout: 10), app.debugDescription)
        activate(identified("imageOcclusion.close"))
        activate(identified("noteEditor.close"))
    }

    func testStudyAudioPlaybackControls() throws {
        let package = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "official", withExtension: "apkg"))
        app.open(package)
        button("Importar")
        if app.buttons["Importar"].firstMatch.waitForExistence(timeout: 5) {
            button("Importar")
        }
        finishTutorialIfPresented()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 30))
        button("OK")
        finishTutorialIfPresented()
        activate(app.buttons["deck.open.UI Imported"])
        button("Estudar agora")
        activate(identified("study.revealAnswer"))
        let moreMenu = identified("study.moreMenu")
        XCTAssertTrue(moreMenu.waitForExistence(timeout: 10), app.debugDescription)
        activate(moreMenu)
        menuButton("Replay áudio", swipeDown: true)
        activate(moreMenu)
        menuButton("Pausar áudio", swipeDown: true)
        activate(moreMenu)
        menuButton("Continuar áudio", swipeDown: true)
    }

    func testStudyRecordOwnVoiceAndReplay() async throws {
        addNote()
        navigate("Baralhos")
        activate(app.buttons["deck.open.Default"])
        button("Estudar agora")

        button("Mais ▾")
        menuButton("Gravar própria voz", swipeDown: true)
        try await Task.sleep(nanoseconds: 8_000_000_000)
        button("Mais ▾")
        menuButton("Parar gravação", swipeDown: true)

        button("Mais ▾")
        menuButton("Replay voz própria", swipeDown: true)
        button("Mais ▾")
        let audioToggle = menuButton("Pausar áudio", swipeDown: true, select: false)
        XCTAssertTrue(audioToggle.exists, app.debugDescription)
        XCTAssertTrue(audioToggle.isHittable, app.debugDescription)
        XCTAssertTrue(audioToggle.label.contains("Pausar áudio"), app.debugDescription)
    }
}

#if os(iOS)
@MainActor
final class AnkiOSSystemLinkUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testStudyWidgetURLOpensStudyOverview() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication(bundleIdentifier: "com.bigbear.AnkiOS")
        XCUIDevice.shared.press(.home)
        let widget = springboard.icons.matching(
            NSPredicate(format: "label == %@ AND value CONTAINS[c] %@", "AnkiOS", "Widget")
        ).firstMatch
        XCTAssertTrue(widget.waitForExistence(timeout: 10), springboard.debugDescription)
        widget.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(app.buttons["deck.overview.close"].waitForExistence(timeout: 20), app.debugDescription)
    }

    func testStudyWidgetCanBeAddedAndOpenedFromHomeScreen() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func labeled(_ labels: [String]) -> XCUIElement {
            springboard.descendants(matching: .any).matching(
                NSPredicate(format: "label IN %@", labels)
            ).firstMatch
        }
        func studyWidget() -> XCUIElement {
            springboard.icons.matching(
                NSPredicate(format: "label == %@ AND value CONTAINS[c] %@", "AnkiOS", "Widget")
            ).firstMatch
        }

        let finishHomeEditing = labeled(["OK", "Concluído", "Done"])
        if finishHomeEditing.waitForExistence(timeout: 2) { finishHomeEditing.tap() }
        XCUIDevice.shared.press(.home)
        var widget = studyWidget()
        if !widget.waitForExistence(timeout: 2) {
            let blankHomeArea = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.68))
            blankHomeArea.press(forDuration: 1.2)
            let editControls = labeled(["Editar"])
            XCTAssertTrue(editControls.waitForExistence(timeout: 10), springboard.debugDescription)
            editControls.tap()
            let addWidget = springboard.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Adicionar Widget", "Add Widget")
            ).firstMatch
            XCTAssertTrue(addWidget.waitForExistence(timeout: 10), springboard.debugDescription)
            addWidget.tap()

            let search = springboard.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 10), springboard.debugDescription)
            search.tap()
            search.typeText("AnkiOS")
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.29)).tap()

            let insertWidget = springboard.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Adicionar Widget", "Add Widget")
            ).firstMatch
            XCTAssertTrue(insertWidget.waitForExistence(timeout: 10), springboard.debugDescription)
            insertWidget.tap()
            let done = labeled(["OK", "Concluído", "Done"])
            if done.waitForExistence(timeout: 5) { done.tap() }
            widget = studyWidget()
        }

        XCTAssertTrue(widget.waitForExistence(timeout: 15), springboard.debugDescription)
        widget.tap()

        let app = XCUIApplication(bundleIdentifier: "com.bigbear.AnkiOS")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(app.buttons["deck.overview.close"].waitForExistence(timeout: 20), app.debugDescription)
    }

    func testStudyWidgetRevealsAndGradesCurrentCard() {
        let app = XCUIApplication(bundleIdentifier: "com.bigbear.AnkiOS")
        if app.state != .notRunning { app.terminate() }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        let existingDeckOptionsClose = app.buttons["deck.options.close"].firstMatch
        if existingDeckOptionsClose.waitForExistence(timeout: 2) {
            let saveExistingDeckOptions = app.buttons.matching(
                NSPredicate(format: "label IN %@", ["Salvar", "Save"])
            ).firstMatch
            if saveExistingDeckOptions.exists {
                saveExistingDeckOptions.tap()
            } else {
                existingDeckOptionsClose.tap()
            }
        }
        let tutorialSkip = app.buttons.matching(NSPredicate(format: "label IN %@", ["Pular", "Skip"])).firstMatch
        if tutorialSkip.waitForExistence(timeout: 2) { tutorialSkip.tap() }
        let hideKeyboardAtStart = app.buttons["keyboard.chevron.compact.down"].firstMatch
        if hideKeyboardAtStart.exists { hideKeyboardAtStart.tap() }
        let decksTab = app.tabBars.buttons["rectangle.stack.fill"].firstMatch
        XCTAssertTrue(decksTab.waitForExistence(timeout: 10), app.debugDescription)
        decksTab.tap()

        let deckName = "UI Widget \(UUID().uuidString.prefix(8))"
        let question = "Widget question \(UUID().uuidString.prefix(8))"
        let answer = "Widget answer \(UUID().uuidString.prefix(8))"
        let deckActions = app.buttons["decks.importActions"].firstMatch
        XCTAssertTrue(deckActions.waitForExistence(timeout: 10), app.debugDescription)
        deckActions.tap()
        let newDeck = app.buttons["decks.newDeck"].firstMatch
        XCTAssertTrue(newDeck.waitForExistence(timeout: 10), app.debugDescription)
        newDeck.tap()
        let deckNameField = app.alerts.textFields.firstMatch
        XCTAssertTrue(deckNameField.waitForExistence(timeout: 10), app.debugDescription)
        deckNameField.tap()
        for character in deckName { deckNameField.typeText(String(character)) }
        app.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Criar", "Create"])).firstMatch.tap()
        let deckOptions = app.buttons["deck.options.\(deckName)"].firstMatch
        XCTAssertTrue(deckOptions.waitForExistence(timeout: 10), app.debugDescription)
        deckOptions.tap()
        let newLimitMode = app.descendants(matching: .any).matching(identifier: "deck.options.limitMode.new").firstMatch
        XCTAssertTrue(newLimitMode.waitForExistence(timeout: 10), app.debugDescription)
        newLimitMode.tap()
        let thisDeck = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["Este baralho", "Esse baralho", "This deck"])
        ).firstMatch
        XCTAssertTrue(thisDeck.waitForExistence(timeout: 10), app.debugDescription)
        thisDeck.tap()
        let newLimit = app.descendants(matching: .any).matching(identifier: "deck.options.limit.new.deck").firstMatch
        XCTAssertTrue(newLimit.waitForExistence(timeout: 10), app.debugDescription)
        let currentNewLimit = Int(String(describing: newLimit.value ?? "").filter { $0.isNumber }) ?? 0
        if currentNewLimit == 0 { newLimit.buttons.element(boundBy: 1).tap() }
        let preparedNewLimit = Int(String(describing: newLimit.value ?? "").filter { $0.isNumber }) ?? 0
        XCTAssertGreaterThan(preparedNewLimit, 0, app.debugDescription)
        let saveDeckOptions = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["Salvar", "Save"])
        ).firstMatch
        XCTAssertTrue(saveDeckOptions.waitForExistence(timeout: 10), app.debugDescription)
        saveDeckOptions.tap()
        let deck = app.buttons["deck.open.\(deckName)"].firstMatch
        XCTAssertTrue(deck.waitForExistence(timeout: 10), app.debugDescription)
        deck.tap()
        app.buttons["deck.overview.close"].tap()

        app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["Adicionar", "Add"])).firstMatch.tap()
        let deckPicker = app.buttons["add.deck"].firstMatch
        XCTAssertTrue(deckPicker.waitForExistence(timeout: 10), app.debugDescription)
        deckPicker.tap()
        let selectedDeck = app.buttons[deckName].firstMatch
        XCTAssertTrue(selectedDeck.waitForExistence(timeout: 10), app.debugDescription)
        selectedDeck.tap()
        let frontByID = app.textViews["field.source.Front"].firstMatch
        let backByID = app.textViews["field.source.Back"].firstMatch
        if !frontByID.exists || !backByID.exists {
            if app.textViews.count < 2 { app.buttons["add.source"].tap() }
        }
        let front = frontByID.exists ? frontByID : app.textViews.element(boundBy: 0)
        let back = backByID.exists ? backByID : app.textViews.element(boundBy: 1)
        XCTAssertTrue(front.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(back.waitForExistence(timeout: 10), app.debugDescription)
        front.tap()
        for character in question { front.typeText(String(character)) }
        let hideKeyboardAfterFront = app.buttons["keyboard.chevron.compact.down"].firstMatch
        if hideKeyboardAfterFront.exists { hideKeyboardAfterFront.tap() }
        let addFormScroll = app.scrollViews.allElementsBoundByIndex.max {
            $0.frame.height < $1.frame.height
        }!
        for _ in 0..<12 {
            if back.frame.maxY <= addFormScroll.frame.maxY { break }
            addFormScroll.swipeUp()
        }
        XCTAssertLessThanOrEqual(back.frame.maxY, addFormScroll.frame.maxY, app.debugDescription)
        back.tap()
        for character in answer { back.typeText(String(character)) }
        XCTAssertEqual(back.value as? String, answer, app.debugDescription)
        let submit = app.descendants(matching: .any).matching(identifier: "add.submit").firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: 10), app.debugDescription)
        submit.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label IN %@", ["Nota adicionada.", "Note added."]))
            .firstMatch.waitForExistence(timeout: 10), app.debugDescription)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func studyWidget() -> XCUIElement {
            springboard.icons.matching(
                NSPredicate(format: "label == %@ AND value CONTAINS[c] %@", "AnkiOS", "Widget")
            ).firstMatch
        }
        let finishHomeEditing = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["OK", "Concluído", "Done"])
        ).firstMatch
        if finishHomeEditing.waitForExistence(timeout: 2) { finishHomeEditing.tap() }
        XCUIDevice.shared.press(.home)
        var widget = studyWidget()
        if !widget.waitForExistence(timeout: 2) {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.68)).press(forDuration: 1.2)
            let editControls = springboard.descendants(matching: .any).matching(
                NSPredicate(format: "label IN %@", ["Editar", "Edit"])
            ).firstMatch
            XCTAssertTrue(editControls.waitForExistence(timeout: 10), springboard.debugDescription)
            editControls.tap()
            let addWidget = springboard.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Adicionar Widget", "Add Widget")
            ).firstMatch
            XCTAssertTrue(addWidget.waitForExistence(timeout: 10), springboard.debugDescription)
            addWidget.tap()
            let search = springboard.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 10), springboard.debugDescription)
            search.tap()
            search.typeText("AnkiOS")
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.29)).tap()
            let insertWidget = springboard.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Adicionar Widget", "Add Widget")
            ).firstMatch
            XCTAssertTrue(insertWidget.waitForExistence(timeout: 10), springboard.debugDescription)
            insertWidget.tap()
            let done = springboard.descendants(matching: .any).matching(
                NSPredicate(format: "label IN %@", ["OK", "Concluído", "Done"])
            ).firstMatch
            if done.waitForExistence(timeout: 5) { done.tap() }
            widget = studyWidget()
        }

        XCTAssertTrue(widget.waitForExistence(timeout: 15), springboard.debugDescription)
        let newCount = springboard.descendants(matching: .any).matching(identifier: "widget.count.Novo").firstMatch
        let learningCount = springboard.descendants(matching: .any).matching(identifier: "widget.count.Aprender").firstMatch
        XCTAssertTrue(newCount.waitForExistence(timeout: 10), springboard.debugDescription)
        XCTAssertEqual(newCount.label, "1", springboard.debugDescription)
        XCTAssertEqual(learningCount.label, "0", springboard.debugDescription)
        let widgetQuestion = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", question)
        ).firstMatch
        XCTAssertTrue(widgetQuestion.waitForExistence(timeout: 20), springboard.debugDescription)
        let reveal = springboard.buttons.matching(
            NSPredicate(format: "label IN %@", ["Mostrar resposta", "Show Answer"])
        ).firstMatch
        XCTAssertTrue(reveal.waitForExistence(timeout: 10), springboard.debugDescription)
        reveal.tap()
        let widgetAnswer = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", answer)
        ).firstMatch
        XCTAssertTrue(widgetAnswer.waitForExistence(timeout: 15), springboard.debugDescription)
        let good = springboard.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Bom", "Good")
        ).firstMatch
        XCTAssertTrue(good.waitForExistence(timeout: 10), springboard.debugDescription)
        good.tap()
        let cardEnteredLearning = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "0"),
            object: newCount
        )
        XCTAssertEqual(XCTWaiter.wait(for: [cardEnteredLearning], timeout: 20), .completed, springboard.debugDescription)
        XCTAssertEqual(learningCount.label, "1", springboard.debugDescription)
        XCTAssertTrue(widgetQuestion.exists, springboard.debugDescription)
        XCTAssertFalse(widgetAnswer.exists, springboard.debugDescription)
        let revealAgain = springboard.buttons.matching(
            NSPredicate(format: "label IN %@", ["Mostrar resposta", "Show Answer"])
        ).firstMatch
        XCTAssertTrue(revealAgain.waitForExistence(timeout: 10), springboard.debugDescription)
    }

    func testStudyWidgetCanBeRemovedFromHomeScreen() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func labeled(_ labels: [String]) -> XCUIElement {
            springboard.descendants(matching: .any).matching(
                NSPredicate(format: "label IN %@", labels)
            ).firstMatch
        }

        let finishHomeEditing = labeled(["OK", "Concluído", "Done"])
        if finishHomeEditing.waitForExistence(timeout: 2) { finishHomeEditing.tap() }
        XCUIDevice.shared.press(.home)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.68)).press(forDuration: 1.2)
        let editControls = labeled(["Editar"])
        XCTAssertTrue(editControls.waitForExistence(timeout: 10), springboard.debugDescription)
        editControls.tap()

        let widgets = springboard.icons.matching(
            NSPredicate(format: "label == %@ AND value CONTAINS[c] %@", "AnkiOS", "Widget")
        )
        XCTAssertTrue(widgets.firstMatch.waitForExistence(timeout: 10), springboard.debugDescription)
        for _ in 0..<4 {
            let widget = widgets.firstMatch
            guard widget.exists else { break }
            let removeWidget = widget.buttons["DeleteButton"].firstMatch
            XCTAssertTrue(removeWidget.waitForExistence(timeout: 5), springboard.debugDescription)
            let frame = removeWidget.frame
            springboard.coordinate(withNormalizedOffset: CGVector(
                dx: frame.midX / springboard.frame.width,
                dy: frame.midY / springboard.frame.height
            )).tap()
            let confirmRemoval = springboard.buttons.matching(
                NSPredicate(format: "label IN %@", ["Remover Widget", "Remove Widget", "Remover", "Remove"])
            ).firstMatch
            if confirmRemoval.waitForExistence(timeout: 3) { confirmRemoval.tap() }
        }
        XCTAssertFalse(widgets.firstMatch.waitForExistence(timeout: 2), springboard.debugDescription)

        let finishAtEnd = labeled(["OK", "Concluído", "Done"])
        if finishAtEnd.waitForExistence(timeout: 5) { finishAtEnd.tap() }
    }
}
#endif
