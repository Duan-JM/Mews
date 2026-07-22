import AppKit
import Foundation

extension MewsAppModelTests {
    static func testNotchPanelControllerTopology() throws {
        _ = NSApplication.shared
        let notifications = NotificationCenter()
        let screenChangeNotification = Notification.Name(
            "MewsNotchPanelControllerTestsScreenChanged"
        )
        var screens = [controllerNotchedScreen()]
        let controller = NotchPanelController(
            notificationCenter: notifications,
            screenChangeNotification: screenChangeNotification,
            screenProvider: { screens }
        )

        try testInitialNotchPresentation(controller)

        screens = [controllerExternalScreen()]
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

        screens = []
        notifications.post(
            name: screenChangeNotification,
            object: nil
        )
        try controllerExpect(
            controllerHasNoScreen(controller),
            "a temporary no-screen transition should hide the panel without crashing"
        )

        screens = [controllerNotchedScreen()]
        notifications.post(
            name: screenChangeNotification,
            object: nil
        )
        try controllerExpect(
            controllerShowsNotch(controller),
            "reconnecting the laptop display should restore notch placement"
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
