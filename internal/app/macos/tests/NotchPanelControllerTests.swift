import AppKit
import Foundation

extension MewsAppModelTests {
    static func testNotchPanelControllerTopology() throws {
        _ = NSApplication.shared
        let notifications = NotificationCenter()
        var screens = [controllerNotchedScreen()]
        let controller = NotchPanelController(
            notificationCenter: notifications,
            screenProvider: { screens }
        )

        try controllerExpect(
            controller.placement?.screenID == "built-in",
            "controller should start on the available notched display"
        )
        try controllerExpect(
            controller.panel.collectionBehavior.contains(.canJoinAllSpaces) &&
                controller.panel.collectionBehavior.contains(.fullScreenAuxiliary) &&
                controller.panel.collectionBehavior.contains(.stationary),
            "panel should remain available across Spaces and full-screen transitions"
        )

        screens = [controllerExternalScreen()]
        notifications.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        try controllerExpect(
            controller.placement?.screenID == "external" &&
                controller.placement?.mode == .topCenter &&
                controller.panel.frame == CGRect(x: 2262, y: 835, width: 420, height: 220),
            "clamshell transition should reposition below the external menu bar"
        )

        screens = []
        notifications.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        try controllerExpect(
            controller.placement == nil && !controller.panel.isVisible,
            "a temporary no-screen transition should hide the panel without crashing"
        )

        screens = [controllerNotchedScreen()]
        notifications.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        try controllerExpect(
            controller.placement?.screenID == "built-in",
            "reconnecting the laptop display should restore notch placement"
        )
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
