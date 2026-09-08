import Foundation

extension MewsAppModelTests {
    static func testNotchShellPresentation() throws {
        let snapshot = notchShellSnapshot()
        try testNotchShellLayout(snapshot: snapshot)
        try testNotchShellHitGeometry(snapshot: snapshot)
        try testTopCenterShellGeometry()
        try testExpandedHeaderNotchAvoidance()
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
            reduceTransparency: false,
            increaseContrast: false
        )
    }

    private static func testTopCenterShellGeometry() throws {
        let snapshot = NotchShellSnapshot(
            visibility: .expanded,
            placementMode: .topCenter,
            panelSize: CGSize(width: 420, height: 220),
            anchorSize: .zero,
            presentationState: MewsPresentationState(event: nil),
            content: .empty,
            transitionStyle: .spatial,
            reduceTransparency: false,
            increaseContrast: false
        )
        let geometry = NotchShellGeometry.resolved(snapshot: snapshot)
        let rect = CGRect(origin: .zero, size: snapshot.panelSize)
        try shellExpect(
            geometry.layout.cornerRadius == 16 &&
                !geometry.shape.path(in: rect).contains(CGPoint(x: 1, y: 1)),
            "top-center mode should use detached popover corner geometry"
        )
        let header = expandedHeaderLayout(
            placementMode: .topCenter,
            anchorHeight: 44,
            sessionCount: 999
        )
        try shellExpect(
            header.topInset == 14,
            "top-center fallback should preserve the existing header geometry"
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
                compact.contentHeight == 0,
            "the collapsed glow must not add any height below the physical notch"
        )
        try shellExpect(
            preview == compact &&
                compact.width == anchorSize.width + 8 &&
                compact.height == anchorSize.height,
            "collapsed glow states should stay tight to the physical notch"
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
                compactFrame.minY == panelFrame.maxY - anchorSize.height,
            "the compact hit region must stay within the measured menu bar height"
        )
        try shellExpect(
            !compactGeometry.contains(
                CGPoint(x: panelFrame.midX, y: compactFrame.minY - 1),
                in: panelFrame
            ),
            "the space below the menu bar must not become a compact hit target"
        )
        try shellExpect(
            !compactFrame.contains(CGPoint(x: panelFrame.midX, y: panelFrame.minY + 20)),
            "transparent panel space should not become a compact hit target"
        )
        try shellExpect(
            compactGeometry.contains(
                CGPoint(x: panelFrame.midX, y: compactFrame.minY + 7),
                in: panelFrame
            ),
            "the bottom notch edge should be part of the hit region"
        )
    }

    private static func testExpandedHeaderNotchAvoidance() throws {
        let shortCount = expandedHeaderLayout(
            anchorHeight: 32,
            sessionCount: 3
        )
        let oneDigitCount = expandedHeaderLayout(
            anchorHeight: 32,
            sessionCount: 9
        )
        let mediumCount = expandedHeaderLayout(
            anchorHeight: 32,
            sessionCount: 31
        )
        let longCount = expandedHeaderLayout(
            anchorHeight: 32,
            sessionCount: 999
        )
        let tallerNotch = expandedHeaderLayout(
            anchorHeight: 44,
            sessionCount: 999
        )
        try shellExpect(
            shortCount.topInset == 14,
            "a non-scrolling session set should keep the existing header slot"
        )
        try shellExpect(
            oneDigitCount.topInset == 38,
            "a scrollable one-digit count should clear a 32-point notch"
        )
        try shellExpect(
            mediumCount.topInset == 38,
            "a two-digit count should clear a 32-point notch"
        )
        try shellExpect(
            longCount.topInset == 38,
            "a three-digit count should remain below the measured notch"
        )
        try shellExpect(
            tallerNotch.topInset == 50,
            "the safe inset should follow a taller physical notch"
        )
    }

    private static func expandedHeaderLayout(
        placementMode: OverlayPlacementMode = .notch,
        anchorHeight: CGFloat,
        sessionCount: Int
    ) -> NotchExpandedHeaderLayout {
        return NotchExpandedHeaderLayout.resolved(
            placementMode: placementMode,
            anchorSize: CGSize(width: 52, height: anchorHeight),
            sessionCount: sessionCount
        )
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
        try shellExpect(
            NotchSurfaceTreatment.resolved(
                placementMode: .notch,
                reduceTransparency: true,
                increaseContrast: true
            ) == .solidBlack,
            "physical-notch mode should preserve its solid black treatment"
        )
        try shellExpect(
            NotchSurfaceTreatment.resolved(
                placementMode: .topCenter,
                reduceTransparency: false,
                increaseContrast: false
            ) == .adaptiveMaterial,
            "top-center mode should use adaptive material by default"
        )
        for preferences in [(true, false), (false, true)] {
            try shellExpect(
                NotchSurfaceTreatment.resolved(
                    placementMode: .topCenter,
                    reduceTransparency: preferences.0,
                    increaseContrast: preferences.1
                ) == .opaqueFallback,
                "accessibility contrast preferences should select an opaque fallback"
            )
        }
    }

    private static func testNotchPresentationPolicy() throws {
        try shellExpect(
            !NotchPanelPresentationPolicy.isVisible(
                visibility: .closed,
                placementMode: .notch,
                hasCollapsedSignal: false
            ),
            "an idle physical notch should not keep an empty overlay visible"
        )
        try shellExpect(
            NotchPanelPresentationPolicy.isVisible(
                visibility: .peek,
                placementMode: .notch,
                hasCollapsedSignal: true
            ),
            "a physical notch should show a transient stop glow"
        )
        for visibility in [NotchVisibility.closed, .peek] {
            try shellExpect(
                !NotchPanelPresentationPolicy.isVisible(
                    visibility: visibility,
                    placementMode: .topCenter,
                    hasCollapsedSignal: true
                ),
                "top-center fallback should hide automatic status surfaces"
            )
        }
        try shellExpect(
            NotchPanelPresentationPolicy.isVisible(
                visibility: .expanded,
                placementMode: .topCenter,
                hasCollapsedSignal: false
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

private struct NotchShellViewTestFailure: Error {
    let message: String
}
