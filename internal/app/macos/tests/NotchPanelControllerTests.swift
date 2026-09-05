import AppKit
import Foundation

extension MewsAppModelTests {
    static func testNotchPanelControllerTopology() throws {
        _ = NSApplication.shared
        let notifications = NotificationCenter()
        let screenChangeNotification = Notification.Name(
            "MewsNotchPanelControllerTestsScreenChanged"
        )
        let screens = ControllerScreenBox(
            screens: [controllerNotchedScreen()]
        )
        let controller = NotchPanelController(
            notificationCenter: notifications,
            screenChangeNotification: screenChangeNotification,
            screenProvider: { screens.screens }
        )

        try testInitialNotchPresentation(controller)
        try testExpandedRowOrderStaysStable(controller)
        try testSwipeCancellationOnPlacementLoss(
            controller: controller,
            notifications: notifications,
            screenChangeNotification: screenChangeNotification,
            screens: screens
        )
        try testScreenTransitions(
            controller: controller,
            notifications: notifications,
            screenChangeNotification: screenChangeNotification,
            screens: screens
        )
    }

    private static func testScreenTransitions(
        controller: NotchPanelController,
        notifications: NotificationCenter,
        screenChangeNotification: Notification.Name,
        screens: ControllerScreenBox
    ) throws {
        screens.screens = [controllerExternalScreen()]
        notifications.post(
            name: screenChangeNotification,
            object: nil
        )
        try controllerExpect(
            controllerUsesExternalFallback(controller),
            "clamshell transition should reposition below the external menu bar"
        )
        try controllerExpect(
            !controller.containsVisibleShell(CGPoint(x: 2472, y: 850)),
            "the closed top-center fallback should not expose a hidden hit region"
        )

        screens.screens = []
        notifications.post(
            name: screenChangeNotification,
            object: nil
        )
        try controllerExpect(
            controllerHasNoScreen(controller),
            "a temporary no-screen transition should hide the panel without crashing"
        )

        screens.screens = [controllerNotchedScreen()]
        notifications.post(
            name: screenChangeNotification,
            object: nil
        )
        try controllerExpect(
            controllerShowsNotch(controller),
            "reconnecting the laptop display should restore notch placement"
        )
    }

    private static func testSwipeCancellationOnPlacementLoss(
        controller: NotchPanelController,
        notifications: NotificationCenter,
        screenChangeNotification: Notification.Name,
        screens: ControllerScreenBox
    ) throws {
        let row = try controllerSwipeRow()
        try configureSwipeFixture(controller: controller, row: row)

        screens.screens = []
        notifications.post(name: screenChangeNotification, object: nil)
        try controllerExpect(
            controller.sessionListSnapshot.rows == [row] &&
                controller.sessionListSnapshot.visual(for: row) == .resting,
            "placement loss should cancel gesture state and stale visual callbacks"
        )
        screens.screens = [controllerNotchedScreen()]
        notifications.post(name: screenChangeNotification, object: nil)
        try controllerExpect(
            !controller.containsVisibleShell(CGPoint(x: 756, y: 800)),
            "restoring placement should not reopen an expanded panel"
        )
    }

    private static func testExpandedRowOrderStaysStable(
        _ controller: NotchPanelController
    ) throws {
        let first = try controllerSwipeRow(
            id: "stable-first",
            evidenceID: "first-1"
        )
        let second = try controllerSwipeRow(
            id: "stable-second",
            evidenceID: "second-1"
        )
        let replacement = try controllerSwipeRow(
            id: "stable-first",
            evidenceID: "first-2"
        )
        controller.update(
            interactionState: NotchInteractionState(
                visibility: .expanded,
                openReason: .click,
                presentationState: MewsPresentationState(event: nil)
            ),
            accessibilityPreferences: controllerAccessibilityPreferences()
        )
        controller.update(content: controllerContent(
            rows: [first, second],
            revision: 1
        ))
        controller.update(content: controllerContent(
            rows: [second, replacement],
            revision: 2
        ))
        try controllerExpect(
            controller.sessionListSnapshot.rows.map(\.id) == [
                replacement.id,
                second.id
            ],
            "new evidence should replace content without moving the row while expanded"
        )
    }

    private static func configureSwipeFixture(
        controller: NotchPanelController,
        row: SessionPresentationRow
    ) throws {
        controller.update(
            interactionState: NotchInteractionState(
                visibility: .expanded,
                openReason: .click,
                presentationState: MewsPresentationState(event: nil)
            ),
            accessibilityPreferences: controllerAccessibilityPreferences()
        )
        controller.update(
            content: NotchPanelContent(
                presentation: SessionPresentation(
                    rows: [row],
                    health: nil,
                    sessionRevision: 10
                ),
                events: [],
                currentEvent: nil
            )
        )
        controller.sessionSwipeInputRouter.begin(
            SessionSwipeInputTarget(
                request: try controllerSwipeTarget(row),
                rowWidth: 320
            )
        )
        controller.sessionSwipeInputRouter.change(
            translationX: -60,
            velocityX: -200
        )
        try controllerExpect(
            controller.sessionListSnapshot.visual(for: row).phase == .dragging,
            "the fixture should begin with an active row drag"
        )
    }

    private static func controllerAccessibilityPreferences()
        -> NotchAccessibilityPreferences {
        return NotchAccessibilityPreferences(
            reduceMotion: false,
            reduceTransparency: false,
            increaseContrast: false
        )
    }

    private static func testInitialNotchPresentation(
        _ controller: NotchPanelController
    ) throws {
        try controllerExpect(
            controllerShowsNotch(controller),
            "controller should start on the available notched display"
        )
        try controllerExpect(
            controller.containsNotchTrigger(CGPoint(x: 756, y: 940)) &&
                controller.containsVisibleShell(CGPoint(x: 756, y: 940)),
            "the visible compact strip below the physical notch should be clickable"
        )
        try controllerExpect(
            !controller.containsNotchTrigger(CGPoint(x: 756, y: 800)) &&
                !controller.containsVisibleShell(CGPoint(x: 756, y: 800)),
            "transparent panel space should not become a compact click target"
        )
        try controllerExpect(
            !controller.containsNotchTrigger(CGPoint(x: 690, y: 970)) &&
                !controller.containsVisibleShell(CGPoint(x: 690, y: 970)),
            "transparent space beside the notch neck should not become a click target"
        )
        try controllerExpect(
            controller.panel.collectionBehavior.contains(.canJoinAllSpaces) &&
                controller.panel.collectionBehavior.contains(.fullScreenAuxiliary) &&
                controller.panel.collectionBehavior.contains(.stationary),
            "panel should remain available across Spaces and full-screen transitions"
        )
        try controllerExpect(
            !controller.panel.hasShadow,
            "the physical-notch shell should not add a detached window shadow"
        )
    }

    private static func controllerShowsNotch(
        _ controller: NotchPanelController
    ) -> Bool {
        controller.placement?.screenID == "built-in" &&
            controller.canPresentNotchAlert
    }

    private static func controllerUsesExternalFallback(
        _ controller: NotchPanelController
    ) -> Bool {
        controller.placement?.screenID == "external" &&
            controller.placement?.mode == .topCenter &&
            !controller.canPresentNotchAlert &&
        controller.panel.hasShadow &&
        controller.panel.frame == CGRect(x: 2262, y: 829, width: 420, height: 220)
    }

    private static func controllerHasNoScreen(
        _ controller: NotchPanelController
    ) -> Bool {
        controller.placement == nil &&
            !controller.canPresentNotchAlert &&
            !controller.panel.hasShadow &&
            !controller.panel.isVisible
    }

    private static func controllerNotchedScreen() -> ScreenSnapshot {
        return ScreenSnapshot(
            id: "built-in",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            safeAreaInsets: OverlayInsets(top: 32, left: 0, bottom: 0, right: 0),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 730, height: 32),
            auxiliaryTopRightArea: CGRect(x: 782, y: 950, width: 730, height: 32),
            isMain: true
        )
    }

    private static func controllerExternalScreen() -> ScreenSnapshot {
        return ScreenSnapshot(
            id: "external",
            frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055),
            safeAreaInsets: OverlayInsets(top: 0, left: 0, bottom: 0, right: 0),
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            isMain: true
        )
    }

    private static func controllerSwipeRow(
        id: String = "panel-swipe",
        evidenceID: String = "panel-evidence"
    ) throws -> SessionPresentationRow {
        guard let identity = SessionIdentity(
            source: "codex",
            sessionID: id
        ) else {
            throw NotchPanelControllerTestFailure(message: "invalid swipe identity")
        }
        let request = SessionDismissalRequest(
            identity: identity,
            evidenceID: evidenceID
        )
        return SessionPresentationRow(
            identity: identity,
            status: .done,
            sourceLabel: "Codex",
            projectLabel: "Mews",
            sessionLabel: id,
            statusLabel: "Stopped",
            statusCode: "STOP",
            returnContext: nil,
            evidenceAt: Date(timeIntervalSince1970: 1_900_000_000),
            priority: .recent,
            evidenceID: request.evidenceID,
            dismissalRequest: request
        )
    }

    private static func controllerContent(
        rows: [SessionPresentationRow],
        revision: UInt64
    ) -> NotchPanelContent {
        return NotchPanelContent(
            presentation: SessionPresentation(
                rows: rows,
                health: nil,
                sessionRevision: revision
            ),
            events: [],
            currentEvent: nil
        )
    }

    private static func controllerSwipeTarget(
        _ row: SessionPresentationRow
    ) throws -> SessionDismissalRequest {
        guard let request = row.dismissalRequest else {
            throw NotchPanelControllerTestFailure(message: "missing swipe target")
        }
        return request
    }

    private static func controllerExpect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw NotchPanelControllerTestFailure(message: message)
        }
    }
}

private struct NotchPanelControllerTestFailure: Error {
    let message: String
}

private final class ControllerScreenBox {
    var screens: [ScreenSnapshot]

    init(screens: [ScreenSnapshot]) {
        self.screens = screens
    }
}
