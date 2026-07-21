import Foundation

extension MewsAppModelTests {
    static func testNotchShellPresentation() throws {
        let snapshot = notchShellSnapshot()
        try testNotchShellLayout(snapshot: snapshot)
        try testNotchShellHitGeometry(snapshot: snapshot)
        try testNotchStatusCopies()
        try testNotchAccessibilityPreferences()
        try testNotchPresentationPolicy()
    }

    private static func notchShellSnapshot() -> NotchShellSnapshot {
        return NotchShellSnapshot(
            visibility: .closed,
            placementMode: .notch,
            panelSize: CGSize(width: 420, height: 220),
            anchorSize: CGSize(width: 180, height: 32),
            presentationState: MewsPresentationState(event: nil),
            content: .empty,
            transitionStyle: .spatial,
            increaseContrast: false
        )
    }

    private static func testNotchShellLayout(
        snapshot: NotchShellSnapshot
    ) throws {
        let panelSize = CGSize(width: 420, height: 220)
        let anchorSize = CGSize(width: 180, height: 32)
        let compact = NotchShellLayout.resolved(snapshot: snapshot)
        let preview = NotchShellLayout.resolved(
            snapshot: snapshot,
            visibility: .peek
        )
        let expanded = NotchShellLayout.resolved(
            snapshot: snapshot,
            visibility: .expanded
        )

        try shellExpect(
            compact.contentTopInset == anchorSize.height &&
                compact.contentHeight >= 22,
            "compact status content should sit below the physical notch"
        )
        try shellExpect(
            preview.width > compact.width &&
                preview.height > compact.height &&
                preview.contentHeight >= 44,
            "the bounded preview should grow from the compact notch shell"
        )
        try shellExpect(
            expanded.width == panelSize.width &&
                expanded.height == panelSize.height,
            "explicit expansion should still use the full panel"
        )
    }

    private static func testNotchShellHitGeometry(
        snapshot: NotchShellSnapshot
    ) throws {
        let anchorSize = snapshot.anchorSize
        let panelFrame = CGRect(x: 546, y: 762, width: 420, height: 220)
        let compactGeometry = NotchShellGeometry.resolved(snapshot: snapshot)
        let compactFrame = compactGeometry.screenFrame(in: panelFrame)
        try shellExpect(
            compactFrame.maxY == panelFrame.maxY &&
                compactFrame.minY < panelFrame.maxY - anchorSize.height,
            "the compact hit region should include the visible strip below the notch"
        )
        try shellExpect(
            !compactFrame.contains(CGPoint(x: panelFrame.midX, y: panelFrame.minY + 20)),
            "transparent panel space should not become a compact hit target"
        )
        try shellExpect(
            compactGeometry.contains(
                CGPoint(x: panelFrame.midX, y: compactFrame.minY + 11),
                in: panelFrame
            ),
            "the visible compact status band should be part of the hit region"
        )
        try shellExpect(
            !compactGeometry.contains(
                CGPoint(x: compactFrame.minX + 4, y: compactFrame.maxY - 4),
                in: panelFrame
            ),
            "transparent space beside the hardware-width neck should not be clickable"
        )
    }

    private static func testNotchStatusCopies() throws {
        let expectedCopies = [
            NotchStatusCopyExpectation(
                status: .idle,
                copy: NotchStatusCopy(code: "IDLE", detail: "Standing by")
            ),
            NotchStatusCopyExpectation(
                status: .running,
                copy: NotchStatusCopy(code: "RUN", detail: "Agent running")
            ),
            NotchStatusCopyExpectation(
                status: .needsInput,
                copy: NotchStatusCopy(code: "ASK", detail: "Needs input")
            ),
            NotchStatusCopyExpectation(
                status: .done,
                copy: NotchStatusCopy(code: "DONE", detail: "Task complete")
            ),
            NotchStatusCopyExpectation(
                status: .failed,
                copy: NotchStatusCopy(code: "FAIL", detail: "Task failed")
            )
        ]
        for expectation in expectedCopies {
            try shellExpect(
                NotchStatusCopy.resolved(status: expectation.status) == expectation.copy,
                "\(expectation.status) should have distinct compact and preview copy"
            )
        }
    }

    private static func testNotchAccessibilityPreferences() throws {
        try shellExpect(
            NotchShellTransitionStyle.resolved(reduceMotion: false) == .spatial,
            "standard motion should allow spatial shell transitions"
        )
        try shellExpect(
            NotchShellTransitionStyle.resolved(reduceMotion: true) == .opacityOnly,
            "Reduce Motion should select non-spatial shell transitions"
        )
        let standard = NotchContrastPalette.resolved(increaseContrast: false)
        let increased = NotchContrastPalette.resolved(increaseContrast: true)
        try shellExpect(
            increased.metadataText > standard.metadataText &&
                increased.separator > standard.separator &&
                increased.disabledText > standard.disabledText,
            "Increase Contrast should strengthen secondary and disabled UI"
        )
    }

    private static func testNotchPresentationPolicy() throws {
        try shellExpect(
            NotchPanelPresentationPolicy.isVisible(
                visibility: .closed,
                placementMode: .notch
            ),
            "a physical notch should keep the compact status visible"
        )
        try shellExpect(
            NotchPanelPresentationPolicy.isVisible(
                visibility: .peek,
                placementMode: .notch
            ),
            "a physical notch should show bounded status previews"
        )
        for visibility in [NotchVisibility.closed, .peek] {
            try shellExpect(
                !NotchPanelPresentationPolicy.isVisible(
                    visibility: visibility,
                    placementMode: .topCenter
                ),
                "top-center fallback should hide automatic status surfaces"
            )
        }
        try shellExpect(
            NotchPanelPresentationPolicy.isVisible(
                visibility: .expanded,
                placementMode: .topCenter
            ),
            "top-center fallback should remain available after an explicit action"
        )
        try shellExpect(
            !NotchPanelPresentationPolicy.acceptsMouseEvents(visibility: .peek) &&
                NotchPanelPresentationPolicy.acceptsMouseEvents(visibility: .expanded),
            "only the expanded panel should accept window interaction"
        )
    }

    private static func shellExpect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw NotchShellViewTestFailure(message: message)
        }
    }
}

private struct NotchStatusCopyExpectation {
    let status: MewsPresentationStatus
    let copy: NotchStatusCopy
}

private struct NotchShellViewTestFailure: Error {
    let message: String
}
