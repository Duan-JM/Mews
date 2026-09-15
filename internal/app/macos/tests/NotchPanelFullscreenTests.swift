import AppKit
import Foundation

extension MewsAppModelTests {
    static func testFullscreenWindowBehavior(
        _ controller: NotchPanelController
    ) throws {
        let glowBehavior = controller.panel.childWindows?.first?.collectionBehavior
        try fullscreenExpect(
            glowBehavior?.contains(.canJoinAllSpaces) == true &&
                glowBehavior?.contains(.fullScreenAuxiliary) == false &&
                glowBehavior?.contains(.stationary) == true,
            "glow window should join normal Spaces without appearing over full-screen content"
        )
        controller.setFullscreenSuppressed(true)
        try fullscreenExpect(
            !controller.panel.isVisible &&
                !controller.canPresentNotchAlert &&
                !controller.containsVisibleShell(CGPoint(x: 756, y: 954)),
            "full-screen suppression should hide the shell and preserve notification fallback"
        )
        controller.setFullscreenSuppressed(false)
        try fullscreenExpect(
            controller.panel.isVisible && controller.canPresentNotchAlert,
            "leaving full-screen content should restore the current notch signal"
        )
    }

    private static func fullscreenExpect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw NotchPanelFullscreenTestFailure(message: message)
        }
    }
}

private struct NotchPanelFullscreenTestFailure: Error {
    let message: String
}
