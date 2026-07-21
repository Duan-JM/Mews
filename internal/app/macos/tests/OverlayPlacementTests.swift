import Foundation

@main
enum OverlayPlacementTests {
    static func main() throws {
        try testNotchedScreenPreference()
        try testMainScreenFallback()
        try testFirstScreenFallback()
        try testNotchPlacementFrame()
        try testTopCenterPlacementFrame()
        try testTopCenterPlacementBelowMenuBar()
        try testWidthCapping()
        try testPlacementHitTesting()
        try testNoScreens()
    }

    private static func testNotchedScreenPreference() throws {
        let main = screen(id: "main", isMain: true)
        let notched = screen(
            id: "notched",
            frame: CGRect(x: 1920, y: 0, width: 1512, height: 982),
            safeTop: 32,
            leftArea: CGRect(x: 1920, y: 950, width: 730, height: 32),
            rightArea: CGRect(x: 2702, y: 950, width: 730, height: 32)
        )

        let target = try require(
            OverlayScreenResolver().resolve(screens: [main, notched]),
            "resolver should choose a screen"
        )
        try expect(target.screen.id == "notched", "a notched screen should be preferred")
        try expect(target.mode == .notch, "a detected notch should use notch placement")
    }

    private static func testMainScreenFallback() throws {
        let first = screen(id: "first")
        let main = screen(id: "main", isMain: true)
        let target = try require(
            OverlayScreenResolver().resolve(screens: [first, main]),
            "resolver should choose the main screen"
        )

        try expect(target.screen.id == "main", "the main screen should be the fallback")
        try expect(target.mode == .topCenter, "a screen without a notch should use top-center placement")
    }

    private static func testFirstScreenFallback() throws {
        let first = screen(id: "first")
        let second = screen(id: "second")
        let target = try require(
            OverlayScreenResolver().resolve(screens: [first, second]),
            "resolver should choose the first screen"
        )

        try expect(target.screen.id == "first", "the first screen should be used when there is no main screen")
        try expect(target.mode == .topCenter, "the first-screen fallback should use top-center placement")
    }

    private static func testNotchPlacementFrame() throws {
        let notched = screen(
            id: "notched",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeTop: 32,
            leftArea: CGRect(x: 0, y: 950, width: 730, height: 32),
            rightArea: CGRect(x: 782, y: 950, width: 730, height: 32)
        )
        let target = try require(
            OverlayScreenResolver().resolve(screens: [notched]),
            "notched target should resolve"
        )

        try expect(
            target.anchorFrame == CGRect(x: 730, y: 950, width: 52, height: 32),
            "safe area and auxiliary top areas should define the notch frame"
        )
        try expect(
            OverlayPlacementCalculator().placement(for: target).frame ==
                CGRect(x: 546, y: 762, width: 420, height: 220),
            "the panel should stay fixed around the notch anchor"
        )
    }

    private static func testTopCenterPlacementFrame() throws {
        let fallback = screen(
            id: "fallback",
            frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        )
        let target = try require(
            OverlayScreenResolver().resolve(screens: [fallback]),
            "fallback target should resolve"
        )

        try expect(
            target.anchorFrame == CGRect(x: -960, y: 1080, width: 0, height: 0),
            "fallback placement should anchor at the screen top center"
        )
        try expect(
            OverlayPlacementCalculator().placement(for: target).frame ==
                CGRect(x: -1170, y: 860, width: 420, height: 220),
            "fallback placement should use a fixed top-center frame"
        )
    }

    private static func testWidthCapping() throws {
        let narrow = screen(
            id: "narrow",
            frame: CGRect(x: 0, y: 0, width: 400, height: 800)
        )
        let target = try require(
            OverlayScreenResolver().resolve(screens: [narrow]),
            "narrow target should resolve"
        )
        let placement = OverlayPlacementCalculator().placement(for: target)

        try expect(
            placement.frame == CGRect(x: 24, y: 580, width: 352, height: 220),
            "panel width should leave a 24-point margin on each side"
        )
    }

    private static func testTopCenterPlacementBelowMenuBar() throws {
        let fallback = screen(
            id: "menu-bar",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
        )
        let target = try require(
            OverlayScreenResolver().resolve(screens: [fallback]),
            "menu-bar fallback target should resolve"
        )

        try expect(
            target.anchorFrame == CGRect(x: 720, y: 875, width: 0, height: 0),
            "top-center fallback should anchor below the menu bar"
        )
        try expect(
            OverlayPlacementCalculator().placement(for: target).frame ==
                CGRect(x: 510, y: 655, width: 420, height: 220),
            "top-center panel should stay below the menu bar"
        )
    }

    private static func testPlacementHitTesting() throws {
        let notched = screen(
            id: "hit-test",
            frame: CGRect(x: 100, y: 50, width: 1512, height: 982),
            safeTop: 32,
            leftArea: CGRect(x: 100, y: 1000, width: 730, height: 32),
            rightArea: CGRect(x: 882, y: 1000, width: 730, height: 32)
        )
        let target = try require(
            OverlayScreenResolver().resolve(screens: [notched]),
            "notched hit-test target should resolve"
        )
        let placement = OverlayPlacementCalculator().placement(for: target)

        try expect(
            placement.anchorFrame == target.anchorFrame,
            "placement should preserve the resolver's physical-notch anchor"
        )
        try expect(
            placement.containsPhysicalNotch(CGPoint(x: 856, y: 1016)),
            "physical-notch hit testing should use the resolved anchor"
        )
        try expect(
            !placement.containsPhysicalNotch(CGPoint(x: 856, y: 900)),
            "points below the anchor should not count as physical-notch clicks"
        )
        try expect(
            placement.containsPanel(CGPoint(x: placement.frame.midX, y: placement.frame.midY)),
            "panel hit testing should use the fixed resolved panel frame"
        )
        try expect(
            placement.containsInteractiveSurface(CGPoint(x: placement.frame.midX, y: placement.frame.midY)),
            "the fixed panel frame should define the expanded interactive surface"
        )

        let fallback = OverlayPlacementCalculator().placement(
            for: try require(
                OverlayScreenResolver().resolve(screens: [screen(id: "fallback", isMain: true)]),
                "fallback hit-test target should resolve"
            )
        )
        try expect(
            !fallback.containsPhysicalNotch(fallback.anchorFrame.origin),
            "top-center fallback should never expose a physical-notch hit region"
        )
    }

    private static func testNoScreens() throws {
        try expect(
            OverlayScreenResolver().resolve(screens: []) == nil,
            "no screens should produce no target"
        )
    }

    private static func screen(
        id: String,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect? = nil,
        isMain: Bool = false,
        safeTop: CGFloat = 0,
        leftArea: CGRect? = nil,
        rightArea: CGRect? = nil
    ) -> ScreenSnapshot {
        ScreenSnapshot(
            id: id,
            frame: frame,
            visibleFrame: visibleFrame ?? frame,
            safeAreaInsets: OverlayInsets(top: safeTop, left: 0, bottom: 0, right: 0),
            auxiliaryTopLeftArea: leftArea,
            auxiliaryTopRightArea: rightArea,
            isMain: isMain
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw TestFailure(message: message)
        }
    }

    private static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else {
            throw TestFailure(message: message)
        }
        return value
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String {
        message
    }
}
