import Foundation
import SwiftUI

extension MewsAppModelTests {
    static func testNotchShellPresentation() throws {
        let snapshot = notchShellSnapshot()
        try testNotchShellLayout(snapshot: snapshot)
        try testNotchSharedSpring(snapshot: snapshot)
        try testNotchSpringClock(snapshot: snapshot)
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

    private static func testNotchSharedSpring(snapshot: NotchShellSnapshot) throws {
        let from = NotchShellLayout.resolved(snapshot: snapshot)
        let to = NotchShellLayout.resolved(snapshot: snapshot, visibility: .expanded)
        let animation = NotchShellAnimation(from: from, to: to)
        try shellExpect(
            animation.frame(at: 0).layout == from && animation.frame(at: 0).velocity == .zero,
            "a shared spring must begin at the displayed layout without inventing velocity"
        )
        let middle = animation.frame(at: 0.09)
        let reversed = NotchShellAnimation(from: middle.layout, to: from, velocity: middle.velocity)
        try shellExpect(
            abs(reversed.frame(at: 0).layout.height - middle.layout.height) < 0.000001,
            "reversing a spring must preserve the displayed position"
        )
        for index in 0..<4 {
            try shellExpect(
                abs(reversed.frame(at: 0).velocity[index] - middle.velocity[index]) < 0.000001,
                "reversing a spring must preserve every geometry component's velocity"
            )
        }
        for (driver, target) in [(animation, to), (reversed, from)] {
            try shellExpect(
                driver.frame(at: driver.duration).layout == target &&
                    driver.frame(at: driver.duration).velocity == .zero,
                "a completed spring must settle at the exact target and stop moving"
            )
        }
        if #available(macOS 14, *) {
            let reference = Spring(response: 0.3, dampingRatio: 0.88)
            for time in [0.02, 0.09, 0.2, 0.3] {
                let expected = reference.value(target: Double(to.height - from.height), time: time)
                let reverseExpected = reference.value(
                    target: Double(from.height - middle.layout.height),
                    initialVelocity: middle.velocity[1], time: time
                )
                try shellExpect(
                    abs(Double(animation.frame(at: time).layout.height - from.height) - expected) < 0.000001 &&
                        abs(Double(reversed.frame(at: time).layout.height - middle.layout.height) -
                            reverseExpected) < 0.000001,
                    "the shared clock must preserve SwiftUI's spring response, damping, and reversal curve"
                )
            }
        }
    }

    private static func testNotchSpringClock(snapshot: NotchShellSnapshot) throws {
        let driver = NotchShellAnimation(
            from: .resolved(snapshot: snapshot), to: .resolved(snapshot: snapshot, visibility: .expanded)
        )
        var frames = 0
        driver.onFrame = { _ in frames += 1 }
        driver.start()
        let deadline = Date().addingTimeInterval(1)
        while frames == 0 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        driver.stop()
        try shellExpect(frames > 0, "the shared animation clock must publish real intermediate frames")
        let stoppedFrames = frames
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        try shellExpect(frames == stoppedFrames, "stopping or hiding must stop the shared animation clock")
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
            "the collapsed contour must use the measured hardware height before applying its stroke"
        )
        try shellExpect(
            preview == compact &&
                compact.width == anchorSize.width + NotchShellLayout.collapsedCornerRadius * 2 &&
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
            "the compact anchor frame must stay aligned with the measured hardware"
        )
        try shellExpect(
            !compactGeometry.contains(
                CGPoint(x: panelFrame.midX, y: compactFrame.minY - 3),
                in: panelFrame
            ),
            "soft glow beyond the solid edge must not become a compact hit target"
        )
        try shellExpect(
            compactGeometry.contains(
                CGPoint(x: panelFrame.midX, y: compactFrame.minY - 0.75),
                in: panelFrame
            ) && compactGeometry.contains(
                CGPoint(x: compactFrame.minX - 0.75, y: compactFrame.midY),
                in: panelFrame
            ),
            "the visible outside stroke should remain clickable at the bottom and sides"
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
