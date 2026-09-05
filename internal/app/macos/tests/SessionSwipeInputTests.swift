import AppKit
import Foundation

extension MewsAppModelTests {
    static func testSessionSwipeInput() throws {
        try testSwipeVelocityTracking()
        try testSwipeRowTargetResolution()
        try testMouseSwipeRecognition()
        try testMouseSwipeCancellation()
    }

    private static func testSwipeVelocityTracking() throws {
        var tracker = SessionSwipeVelocityTracker()
        tracker.update(deltaX: -4, timestamp: 1)
        tracker.update(deltaX: -8, timestamp: 1.02)
        try swipeInputExpect(
            abs(tracker.velocityX + 400) < 0.001,
            "velocity tracking should preserve the physical horizontal direction"
        )
        tracker.update(deltaX: 4, timestamp: 1.04)
        try swipeInputExpect(
            tracker.velocityX < 0 && tracker.velocityX > -400,
            "velocity tracking should hand off continuously instead of jumping to the last sample"
        )

        tracker.update(deltaX: 4, timestamp: 1.06)
        tracker.update(deltaX: 4, timestamp: 1.08)
        try swipeInputExpect(
            abs(tracker.velocityX - 200) < 0.001,
            "release velocity should use only the latest three input frames"
        )
    }

    private static func testSwipeRowTargetResolution() throws {
        let fixture = try SwipeInputFixture()
        let inside = try fixture.mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 40, y: 21),
            timestamp: 1
        )
        let outside = try fixture.mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 40, y: 70),
            timestamp: 1
        )
        try swipeInputExpect(
            fixture.router.inputTarget(for: inside)?.request == fixture.request,
            "row routing should resolve the evidence-scoped target under the pointer"
        )
        try swipeInputExpect(
            fixture.router.inputTarget(for: outside) == nil,
            "row routing should reject transparent space outside the row"
        )
    }

    private static func testMouseSwipeRecognition() throws {
        let fixture = try SwipeInputFixture()
        let recognizer = SessionMouseSwipeRecognizer(inputRouter: fixture.router)
        fixture.container.addGestureRecognizer(recognizer)
        fixture.router.attach(mouseRecognizer: recognizer)
        try swipeInputExpect(
            recognizer.delaysPrimaryMouseButtonEvents,
            "the recognizer should delay clicks until the eight-point slop resolves"
        )

        recognizer.mouseDown(with: try fixture.mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 100, y: 21),
            timestamp: 1
        ))
        recognizer.mouseDragged(with: try fixture.mouseEvent(
            type: .leftMouseDragged,
            location: CGPoint(x: 84, y: 20),
            timestamp: 1.02
        ))

        try swipeInputExpect(
            fixture.begun == [fixture.request] &&
                fixture.translations.last == -16,
            "a horizontal mouse drag should capture one evidence-scoped row"
        )

        let verticalFixture = try SwipeInputFixture()
        let verticalRecognizer = SessionMouseSwipeRecognizer(
            inputRouter: verticalFixture.router
        )
        verticalFixture.container.addGestureRecognizer(verticalRecognizer)
        verticalRecognizer.mouseDown(with: try verticalFixture.mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 100, y: 21),
            timestamp: 2
        ))
        verticalRecognizer.mouseDragged(with: try verticalFixture.mouseEvent(
            type: .leftMouseDragged,
            location: CGPoint(x: 98, y: 37),
            timestamp: 2.02
        ))
        try swipeInputExpect(
            verticalFixture.begun.isEmpty &&
                verticalFixture.verticalInteractionCount == 1,
            "a vertical mouse drag should consume the click and close revealed actions"
        )
    }

    private static func testMouseSwipeCancellation() throws {
        let fixture = try SwipeInputFixture()
        let recognizer = SessionMouseSwipeRecognizer(inputRouter: fixture.router)
        fixture.container.addGestureRecognizer(recognizer)
        fixture.router.attach(mouseRecognizer: recognizer)

        recognizer.mouseDown(with: try fixture.mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 100, y: 21),
            timestamp: 3
        ))
        fixture.router.cancelAllInput()
        recognizer.mouseDragged(with: try fixture.mouseEvent(
            type: .leftMouseDragged,
            location: CGPoint(x: 70, y: 21),
            timestamp: 3.02
        ))
        try swipeInputExpect(
            fixture.begun.isEmpty,
            "teardown during mouse slop should clear the captured row target"
        )

        let activeFixture = try SwipeInputFixture()
        let activeRecognizer = SessionMouseSwipeRecognizer(
            inputRouter: activeFixture.router
        )
        activeFixture.container.addGestureRecognizer(activeRecognizer)
        activeFixture.router.attach(mouseRecognizer: activeRecognizer)
        activeRecognizer.mouseDown(with: try activeFixture.mouseEvent(
            type: .leftMouseDown,
            location: CGPoint(x: 100, y: 21),
            timestamp: 4
        ))
        activeRecognizer.mouseDragged(with: try activeFixture.mouseEvent(
            type: .leftMouseDragged,
            location: CGPoint(x: 80, y: 21),
            timestamp: 4.02
        ))
        activeFixture.router.cancelAllInput()
        try swipeInputExpect(
            activeFixture.cancelCount == 1,
            "teardown during an active mouse swipe should cancel presentation state once"
        )
    }

    private static func swipeInputExpect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw SessionSwipeInputTestError.expectation(message)
        }
    }
}

@MainActor
private final class SwipeInputFixture {
    let window: NSWindow
    let container: NSView
    let marker: SessionSwipeRowMarkerView
    let request: SessionDismissalRequest
    let router: SessionSwipeInputRouter
    private let recorder: SwipeInputRecorder

    var begun: [SessionDismissalRequest] {
        return recorder.begun
    }

    var translations: [CGFloat] {
        return recorder.translations
    }

    var endVelocities: [CGFloat] {
        return recorder.endVelocities
    }

    var verticalInteractionCount: Int {
        return recorder.verticalInteractionCount
    }

    var cancelCount: Int {
        return recorder.cancelCount
    }

    init() throws {
        guard let identity = SessionIdentity(source: "codex", sessionID: "input") else {
            throw SessionSwipeInputTestError.invalidFixture
        }
        request = SessionDismissalRequest(
            identity: identity,
            evidenceID: "input-evidence"
        )
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        container = NSView(frame: window.contentView?.bounds ?? .zero)
        marker = SessionSwipeRowMarkerView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 42)
        )
        let recorder = SwipeInputRecorder()
        self.recorder = recorder
        router = SessionSwipeInputRouter(
            onBegin: { request, _ in
                recorder.begun.append(request)
            },
            onChange: { translation, _ in
                recorder.translations.append(translation)
            },
            onEnd: { velocity in
                recorder.endVelocities.append(velocity)
            },
            onCancel: {
                recorder.cancelCount += 1
            },
            onVerticalScroll: {
                recorder.verticalInteractionCount += 1
            }
        )
        window.contentView = container
        container.addSubview(marker)
        marker.inputRouter = router
        marker.request = request
        marker.updateRegistration()
    }

    func mouseEvent(
        type: NSEvent.EventType,
        location: CGPoint,
        timestamp: TimeInterval
    ) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else {
            throw SessionSwipeInputTestError.invalidFixture
        }
        return event
    }
}

private final class SwipeInputRecorder {
    var begun: [SessionDismissalRequest] = []
    var translations: [CGFloat] = []
    var endVelocities: [CGFloat] = []
    var verticalInteractionCount = 0
    var cancelCount = 0
}

private enum SessionSwipeInputTestError: Error {
    case invalidFixture
    case expectation(String)
}
