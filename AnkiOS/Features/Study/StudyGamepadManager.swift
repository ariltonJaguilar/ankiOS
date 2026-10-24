#if os(iOS)
import Combine
import Foundation
import GameController

@MainActor
final class StudyGamepadManager: ObservableObject {
    private var preferences = ReviewGamepadPreferences()
    private var actionHandler: ((ReviewGestureAction) -> Void)?
    private var scrollHandler: ((Int) -> Void)?
    private var connectedControllers: [GCController] = []
    private var connectionObserver: NSObjectProtocol?
    private var disconnectionObserver: NSObjectProtocol?
    private var lastScrollAt: [String: TimeInterval] = [:]
    private var isObserving = false
#if DEBUG
    private var uiTestVirtualController: GCVirtualController?
#endif

    func configure(
        preferences: ReviewGamepadPreferences,
        onAction: @escaping (ReviewGestureAction) -> Void,
        onScroll: @escaping (Int) -> Void
    ) {
        self.preferences = preferences
        actionHandler = onAction
        scrollHandler = onScroll

        if !isObserving {
            isObserving = true
            connectionObserver = NotificationCenter.default.addObserver(
                forName: .GCControllerDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshControllers()
                }
            }
            disconnectionObserver = NotificationCenter.default.addObserver(
                forName: .GCControllerDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshControllers()
                }
            }
            GCController.controllers().forEach(attach)
        }

        connectedControllers.forEach(installHandlers)
#if DEBUG
        connectUITestVirtualControllerIfRequested()
#endif
    }

    func stop() {
        if let connectionObserver {
            NotificationCenter.default.removeObserver(connectionObserver)
            self.connectionObserver = nil
        }
        if let disconnectionObserver {
            NotificationCenter.default.removeObserver(disconnectionObserver)
            self.disconnectionObserver = nil
        }
        connectedControllers.forEach(clearHandlers)
        connectedControllers.removeAll()
#if DEBUG
        uiTestVirtualController?.disconnect()
        uiTestVirtualController = nil
#endif
        actionHandler = nil
        scrollHandler = nil
        lastScrollAt.removeAll()
        isObserving = false
    }

    private func attach(_ controller: GCController) {
        guard controller.extendedGamepad != nil,
              !connectedControllers.contains(where: { $0 === controller }) else { return }
        connectedControllers.append(controller)
        installHandlers(controller)
    }

    private func refreshControllers() {
        let currentControllers = GCController.controllers().filter { $0.extendedGamepad != nil }
        connectedControllers
            .filter { existing in !currentControllers.contains(where: { $0 === existing }) }
            .forEach(detach)
        currentControllers.forEach(attach)
    }

    private func detach(_ controller: GCController) {
        clearHandlers(controller)
        connectedControllers.removeAll { $0 === controller }
    }

    private func installHandlers(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        bind(gamepad.buttonA, controlID: "buttonA")
        bind(gamepad.buttonB, controlID: "buttonB")
        bind(gamepad.buttonX, controlID: "buttonX")
        bind(gamepad.buttonY, controlID: "buttonY")
        bind(gamepad.leftShoulder, controlID: "leftShoulder")
        bind(gamepad.rightShoulder, controlID: "rightShoulder")
        bind(gamepad.leftTrigger, controlID: "leftTrigger")
        bind(gamepad.rightTrigger, controlID: "rightTrigger")
        if let button = gamepad.leftThumbstickButton { bind(button, controlID: "leftThumbstickButton") }
        if let button = gamepad.rightThumbstickButton { bind(button, controlID: "rightThumbstickButton") }
        if let button = gamepad.buttonOptions { bind(button, controlID: "options") }
        bind(gamepad.buttonMenu, controlID: "menu")
        bind(gamepad.dpad.up, controlID: "dpadUp")
        bind(gamepad.dpad.down, controlID: "dpadDown")
        bind(gamepad.dpad.left, controlID: "dpadLeft")
        bind(gamepad.dpad.right, controlID: "dpadRight")
        bindScroll(gamepad.leftThumbstick, source: "left")
        bindScroll(gamepad.rightThumbstick, source: "right")
    }

    private func bind(_ button: GCControllerButtonInput, controlID: String) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            Task { @MainActor [weak self] in
                self?.actionHandler?(self?.preferences.action(for: controlID) ?? .none)
            }
        }
    }

    private func bindScroll(_ directionPad: GCControllerDirectionPad, source: String) {
        directionPad.valueChangedHandler = { [weak self] _, _, yValue in
            Task { @MainActor [weak self] in
                self?.scroll(value: yValue, source: source)
            }
        }
    }

    private func scroll(value: Float, source: String) {
        let deadZone = Float(preferences.thumbpadDeadZone)
        guard abs(value) >= deadZone else { return }
        let now = Date.timeIntervalSinceReferenceDate
        guard now - (lastScrollAt[source] ?? 0) >= 0.18 else { return }
        lastScrollAt[source] = now
        scrollHandler?(value > 0 ? -1 : 1)
    }

#if DEBUG
    private func connectUITestVirtualControllerIfRequested() {
        guard uiTestVirtualController == nil,
              ProcessInfo.processInfo.environment["ANKIOS_UI_TEST_VIRTUAL_GAMEPAD"] == "buttonA" else { return }
        let configuration = GCVirtualController.Configuration()
        configuration.elements = [GCInputButtonA]
        configuration.isHidden = true
        let controller = GCVirtualController(configuration: configuration)
        uiTestVirtualController = controller
        Task { @MainActor in
            guard (try? await controller.connect()) != nil else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            controller.setValue(1, forButtonElement: GCInputButtonA)
            try? await Task.sleep(nanoseconds: 150_000_000)
            controller.setValue(0, forButtonElement: GCInputButtonA)
        }
    }
#endif

    private func clearHandlers(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        for button in [gamepad.buttonA, gamepad.buttonB, gamepad.buttonX, gamepad.buttonY,
                       gamepad.leftShoulder, gamepad.rightShoulder, gamepad.leftTrigger,
                       gamepad.rightTrigger, gamepad.buttonMenu] {
            button.pressedChangedHandler = nil
        }
        gamepad.leftThumbstickButton?.pressedChangedHandler = nil
        gamepad.rightThumbstickButton?.pressedChangedHandler = nil
        gamepad.buttonOptions?.pressedChangedHandler = nil
        gamepad.dpad.up.pressedChangedHandler = nil
        gamepad.dpad.down.pressedChangedHandler = nil
        gamepad.dpad.left.pressedChangedHandler = nil
        gamepad.dpad.right.pressedChangedHandler = nil
        gamepad.leftThumbstick.valueChangedHandler = nil
        gamepad.rightThumbstick.valueChangedHandler = nil
    }
}
#endif
