import AppKit
import Foundation

@MainActor
final class NotchInteractionCoordinator: NSObject {
    typealias StatusItemFrameProvider = () -> CGRect?

    private let panelController: NotchPanelController
    private let statusItemFrameProvider: StatusItemFrameProvider
    private let workspace: NSWorkspace
    private let log: (String) -> Void
    private var model: NotchInteractionModel
    private var accessibilityPreferences: NotchAccessibilityPreferences
    private var started = false

    private var localEventMonitor: Any?
    private var globalClickMonitor: Any?
    private var globalHoverMonitor: Any?
    private var hoverOpenTimer: Timer?
    private var hoverCloseTimer: Timer?
    private var notificationPeekTimer: Timer?

    init(
        panelController: NotchPanelController,
        presentationState: MewsPresentationState,
        statusItemFrameProvider: @escaping StatusItemFrameProvider,
        workspace: NSWorkspace = .shared,
        log: @escaping (String) -> Void
    ) {
        self.panelController = panelController
        self.statusItemFrameProvider = statusItemFrameProvider
        self.workspace = workspace
        self.log = log
        model = NotchInteractionModel(presentationState: presentationState)
        accessibilityPreferences = NotchAccessibilityPreferences(
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        installLocalEventMonitor()
        installGlobalClickMonitor()
        installGlobalHoverMonitor()
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        render()
    }

    func stop() {
        guard started else { return }
        started = false
        invalidateTimers()
        removeEventMonitors()
        workspace.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        panelController.hide()
    }

    func logoPrimaryClicked() {
        send(.logoPrimaryClick)
    }

    private func installLocalEventMonitor() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.handleLocalEvent(event)
            return event
        }
        if localEventMonitor == nil {
            log("Local notch interaction monitor unavailable; the menu bar logo remains functional")
        }
    }

    private func installGlobalClickMonitor() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.handleMouseDown(event)
        }
        if globalClickMonitor == nil {
            log("Global notch click monitor unavailable; the menu bar logo remains functional")
        }
    }

    private func installGlobalHoverMonitor() {
        globalHoverMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved]
        ) { [weak self] event in
            self?.handleMouseMoved(event)
        }
        if globalHoverMonitor == nil {
            log(
                "Global notch hover monitor unavailable; logo click and top-center fallback remain functional"
            )
        }
    }

    private func handleLocalEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved:
            handleMouseMoved(event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            handleMouseDown(event)
        default:
            break
        }
    }

    private func handleMouseMoved(_ event: NSEvent) {
        guard panelController.placement != nil else {
            send(.pointerMoved(isInsideNotch: false, isInsideInteractiveSurface: false))
            return
        }
        let point = screenPoint(for: event)
        send(
            .pointerMoved(
                isInsideNotch: panelController.containsNotchTrigger(point),
                isInsideInteractiveSurface: panelController.containsVisibleShell(point)
            )
        )
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard panelController.placement != nil else {
            send(.outsideClick)
            return
        }
        let point = screenPoint(for: event)
        let targetsControl = panelController.eventTargetsControl(event)

        if event.type == .leftMouseDown && panelController.containsNotchTrigger(point) {
            send(.notchClick(isPanelControl: targetsControl))
            return
        }
        if panelController.containsVisibleShell(point) {
            panelController.prepareForPanelInteraction(event: event, targetsControl: targetsControl)
            if event.type == .leftMouseDown {
                send(.panelSurfaceClick(isPanelControl: targetsControl))
            }
            return
        }
        if statusItemFrameProvider()?.contains(point) == true {
            return
        }
        send(.outsideClick)
    }

    private func screenPoint(for event: NSEvent) -> CGPoint {
        guard let window = event.window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func send(_ action: NotchInteractionAction) {
        let previousState = model.state
        let effects = model.send(action)
        apply(effects: effects)
        if model.state != previousState {
            render()
        }
    }

    private func render() {
        panelController.update(
            interactionState: model.state,
            accessibilityPreferences: accessibilityPreferences
        )
    }

    private func apply(effects: [NotchInteractionEffect]) {
        for effect in effects {
            switch effect {
            case let .scheduleHoverOpen(after):
                scheduleHoverOpen(after: after)
            case .cancelHoverOpen:
                hoverOpenTimer?.invalidate()
                hoverOpenTimer = nil
            case let .scheduleHoverClose(after):
                scheduleHoverClose(after: after)
            case .cancelHoverClose:
                hoverCloseTimer?.invalidate()
                hoverCloseTimer = nil
            case let .scheduleNotificationPeek(sequence, after):
                scheduleNotificationPeek(sequence: sequence, after: after)
            case .cancelNotificationPeek:
                notificationPeekTimer?.invalidate()
                notificationPeekTimer = nil
            }
        }
    }

    private func scheduleHoverOpen(after delay: TimeInterval) {
        hoverOpenTimer?.invalidate()
        hoverOpenTimer = oneShotTimer(after: delay) { [weak self] in
            self?.hoverOpenTimer = nil
            self?.send(.hoverOpenTimerFired)
        }
    }

    private func scheduleHoverClose(after delay: TimeInterval) {
        hoverCloseTimer?.invalidate()
        hoverCloseTimer = oneShotTimer(after: delay) { [weak self] in
            self?.hoverCloseTimer = nil
            self?.send(.hoverCloseTimerFired)
        }
    }

    private func scheduleNotificationPeek(
        sequence: Int,
        after delay: TimeInterval
    ) {
        notificationPeekTimer?.invalidate()
        notificationPeekTimer = oneShotTimer(after: delay) { [weak self] in
            self?.notificationPeekTimer = nil
            self?.send(.notificationPeekTimerFired(sequence: sequence))
        }
    }

    private func oneShotTimer(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            action()
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        let updatedPreferences = NotchAccessibilityPreferences(
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
        guard accessibilityPreferences != updatedPreferences else {
            return
        }
        accessibilityPreferences = updatedPreferences
        render()
    }

    private func invalidateTimers() {
        hoverOpenTimer?.invalidate()
        hoverCloseTimer?.invalidate()
        notificationPeekTimer?.invalidate()
        hoverOpenTimer = nil
        hoverCloseTimer = nil
        notificationPeekTimer = nil
    }

    private func removeEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
        if let globalHoverMonitor {
            NSEvent.removeMonitor(globalHoverMonitor)
        }
        localEventMonitor = nil
        globalClickMonitor = nil
        globalHoverMonitor = nil
    }
}

extension NotchInteractionCoordinator {
    var canPresentStopTransition: Bool {
        return panelController.canPresentNotchAlert
    }

    func placementDidBecomeUnavailable() {
        send(.placementUnavailable)
    }

    func update(
        presentationState: MewsPresentationState,
        stopTransitionIdentifier: String?
    ) {
        send(.presentationSynchronized(presentationState))
        if let stopTransitionIdentifier {
            send(.stoppedTransition(identifier: stopTransitionIdentifier))
        }
    }
}
