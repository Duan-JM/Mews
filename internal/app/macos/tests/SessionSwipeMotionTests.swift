import AppKit
import SwiftUI

extension MewsAppModelTests {
    static func testSessionSwipeMotion() throws {
        try testInterpolatedActionGeometry()
        try testNativeSamplingCompletesAfterSlowCapture()
        try testNativeSamplingTimeout()
        try testNativeSwipeSettle()
        try testNativeSwipeTrack()
        try testNativeSwipeMaterial()
        try testNativeFullSwipeRetreat()
        try testNativeSwipeWriteFailure()
        try testNativeSwipeRemoval(captureProcessingDelay: 0)
        try testNativeSwipeRemoval(captureProcessingDelay: 0.2)
        try testNativeReducedMotionSwipe()
    }

    private static func testNativeSamplingCompletesAfterSlowCapture() throws {
        let fixture = try SwipeMotionFixture()
        defer { fixture.close() }
        fixture.beginDrag(distance: 63)
        fixture.captureProcessingDelay = 0.45
        fixture.model.inputRouter.change(translationX: -65, velocityX: -240)
        let frames = try fixture.sampleActionFrames(until: { abs($0.button.width - 308) <= 1 })
        try motionExpect(
            frames.count >= 2 && frames.contains { $0.button.width > 0 && $0.button.width < 300 } &&
                abs((frames.last?.button.width ?? 0) - 308) <= 1 && fixture.persistence.requests.isEmpty,
            "slow bitmap analysis must not truncate sampling before the rendered target; frames \(frames)"
        )
    }

    private static func testNativeSamplingTimeout() throws {
        let fixture = try SwipeMotionFixture()
        defer { fixture.close() }
        fixture.beginDrag(distance: 63)
        do {
            _ = try fixture.sampleActionFrames(until: { _ in false })
        } catch SwipeMotionTestError.samplingTimedOut(let frames) {
            try motionExpect(
                !frames.isEmpty && frames.contains { $0.button.width > 0 },
                "a sampling timeout must retain the rendered frames instead of reporting success"
            )
            return
        }
        throw SwipeMotionTestError.expectation("an unreachable rendered target must time out")
    }

    private static func testNativeSwipeMaterial() throws {
        for colorScheme in [ColorScheme.light, .dark] {
            let fixture = try SwipeMotionFixture(
                colorScheme: colorScheme, reduceTransparency: false
            )
            defer { fixture.close() }
            fixture.beginDrag(distance: 63)
            let opacity = try fixture.captureTrackOpacity()
            let button = try fixture.captureActionBounds()
            try motionExpect(
                opacity > 0.5 && abs(button.minX - 270) <= 1 &&
                    abs(button.width - 44) <= 1 && fixture.persistence.requests.isEmpty,
                "normal appearance must render native material behind the separate HIDE button; alpha \(opacity)"
            )
        }
    }

    private static func testInterpolatedActionGeometry() throws {
        var action = SessionSwipeActionView(
            geometry: SessionSwipeActionGeometry(trackWidth: 56),
            isFullSwipe: false,
            labelOpacity: 1,
            snapshot: .initial,
            palette: .resolved(increaseContrast: false),
            onHide: {}
        )
        for width: CGFloat in [0, 4, 8, 16, 24] {
            action.animatableData = width + 12
            try motionExpect(
                action.geometry.buttonWidth == width && action.geometry.height == width &&
                    action.geometry.cornerRadius == width / 2 && action.geometry.labelOpacity == 0,
                "interpolated reveal and closing frames must stay circular without partial HIDE text"
            )
        }
        action.animatableData = 44
        try motionExpect(
            action.geometry.height == 24 && action.geometry.cornerRadius == 8.8 &&
                action.geometry.labelOpacity == 0.4,
            "the circle should morph into the compact button while its full label fades in"
        )
        action.animatableData = 240
        try motionExpect(
            action.geometry.trackWidth == 240 && action.geometry.buttonWidth == 228 &&
                action.geometry.height == 24 && action.geometry.cornerRadius == 4 &&
                action.geometry.verticalOffset == 0 &&
                action.geometry.edgeHorizontalRadius == 11 &&
                action.geometry.edgeVerticalRadius == 13,
            "a longer track must elongate the red button while preserving its height, corners and centering"
        )
    }

    private static func testNativeSwipeSettle() throws {
        let fixture = try SwipeMotionFixture()
        defer { fixture.close() }
        let controlBounds = try [238, 298].map { try fixture.captureControlBounds(column: $0) }
        try motionExpect(
            controlBounds.allSatisfy {
                $0.height == SessionRowLayout.actionButtonHeight &&
                    abs($0.midY - SessionRowLayout.rowHeight / 2) <= 0.5
            },
            "RETURN and COPY must render at the vertical center of the row; rendered \(controlBounds)"
        )
        fixture.beginDrag(distance: 28)
        let dragged = try fixture.captureActionBounds()
        try motionExpect(
            abs(dragged.width - 9) <= 1 && abs(dragged.height - 9) <= 1,
            "a narrow native reveal must preserve the gutter before showing a circular action; rendered \(dragged)"
        )
        fixture.model.inputRouter.end(velocityX: 0)
        let frames = try fixture.sampleActionBounds(until: { abs($0.width - 44) <= 1 })
        try motionExpect(
            frames.contains { $0.width > 19 && $0.width < 41 },
            "the nested hosting tree must render circle-to-button settling frames, not jump to 44"
        )
        try motionExpect(
            abs((frames.last?.width ?? 0) - 44) <= 1 && fixture.persistence.requests.isEmpty,
            "a short swipe should settle to one 44-point HIDE button without submitting"
        )
        try motionExpect(
            abs((frames.last?.midY ?? 0) - SessionRowLayout.rowHeight / 2) <= 0.5,
            "the settled HIDE button must use the same vertical center as RETURN and COPY"
        )
    }

    private static func testNativeSwipeTrack() throws {
        for placementMode in [OverlayPlacementMode.notch, .topCenter] {
            for reduceTransparency in [false, true] {
                for increaseContrast in [false, true] {
                    try assertNativeSwipeTrack(
                        placementMode: placementMode,
                        reduceTransparency: reduceTransparency,
                        increaseContrast: increaseContrast
                    )
                }
            }
        }
    }

    private static func assertNativeSwipeTrack(
        placementMode: OverlayPlacementMode,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) throws {
        let fixture = try SwipeMotionFixture(
            placementMode: placementMode,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
        defer { fixture.close() }
        fixture.beginDrag(distance: 56)
        let initiallyRevealed = try fixture.captureActionFrame()
        fixture.model.inputRouter.change(translationX: -63, velocityX: -240)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        let dragged = try fixture.captureActionFrame()
        let cornerTrack = try fixture.captureTrackWidth(row: 2)
        let segments = try fixture.capturePaintedSegments(row: 21)
        let trailingSegments = Array(segments.suffix(2))
        let draggedTrack = CGFloat(trailingSegments.last?.count ?? 0)
        try motionExpect(
            abs(dragged.button.width - 44) <= 1 && abs(draggedTrack - 56) <= 1 &&
                abs(initiallyRevealed.button.minX - dragged.button.minX - 7) <= 1 &&
                abs(initiallyRevealed.button.maxX - dragged.button.maxX) <= 1 &&
                cornerTrack > draggedTrack && cornerTrack <= draggedTrack + 11 &&
                trailingSegments.count == 2 &&
                trailingSegments[1].lowerBound - trailingSegments[0].upperBound == 7,
            "the red button must grow seven points left with its right edge fixed; "
                + "initial \(initiallyRevealed), rendered \(dragged), "
                + "track \(draggedTrack), corner \(cornerTrack), segments \(segments)"
        )
        fixture.model.inputRouter.end(velocityX: 0)
        _ = try fixture.sampleActionBounds(until: { abs($0.width - 44) <= 1 })
        let settledSegments = try fixture.capturePaintedSegments(row: 21)
        let settledTrack = CGFloat(settledSegments.last?.count ?? 0)
        try motionExpect(
            abs(settledTrack - 56) <= 1 && fixture.persistence.requests.isEmpty,
            "release below twenty percent must preserve the seven-point gutter"
        )
        fixture.beginDrag(distance: 9)
        let full = try fixture.sampleActionBounds(until: { abs($0.width - 308) <= 1 })
        let fullTrack = try fixture.captureTrackWidth(row: 2)
        try motionExpect(
            abs(fullTrack - 320) <= 1 &&
                abs((full.last?.width ?? 0) - 308) <= 1 &&
                full.allSatisfy {
                    abs($0.maxX - 314) <= 1 && abs($0.height - 24) <= 1
                },
            "full reveal must stretch the red button left across the neutral track, never translate it"
        )
    }

    private static func testNativeFullSwipeRetreat() throws {
        let fixture = try SwipeMotionFixture()
        defer { fixture.close() }
        fixture.beginDrag(distance: 63)
        fixture.model.inputRouter.change(translationX: -65, velocityX: -240)
        let armedFrames = try fixture.sampleActionFrames(until: { frame in
            return try abs(frame.button.width - 308) <= 1 &&
                abs(fixture.captureTrackOpacity(column: 0, row: 20) - fixture.captureTrackOpacity()) <= 1.0 / 255
        })
        try motionExpect(
            armedFrames.allSatisfy {
                abs($0.button.maxX - 314) <= 1 && abs($0.button.height - 24) <= 1 &&
                    $0.label.width > 15 && abs($0.label.minX - $0.button.minX - 11) <= 2
            } &&
                armedFrames.contains { $0.button.width > 80 && $0.button.width < 300 } &&
                abs((armedFrames.last?.button.width ?? 0) - 308) <= 1,
            "the red button must lengthen while only HIDE text snaps to its leading inset; frames \(armedFrames)"
        )
        let leadingOpacity = try fixture.captureTrackOpacity(column: 0, row: 20)
        let trackOpacity = try fixture.captureTrackOpacity()
        try motionExpect(
            abs(leadingOpacity - trackOpacity) <= 1.0 / 255,
            "full reveal must leave no foreground border; alpha \(leadingOpacity) vs \(trackOpacity)"
        )
        fixture.model.inputRouter.change(translationX: -49, velocityX: 240)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        let held = try fixture.captureActionBounds()
        try motionExpect(
            abs(held.minX - 6) <= 1 && abs(held.width - 308) <= 1 && abs(held.height - 24) <= 1 &&
                fixture.persistence.requests.isEmpty,
            "armed hysteresis must retain full-row feedback without submitting"
        )
        fixture.model.inputRouter.change(translationX: -47, velocityX: 240)
        let retreatFrames = try fixture.sampleActionBounds(until: { abs($0.width - 28) <= 1 })
        try motionExpect(
            retreatFrames.contains { $0.width > 40 && $0.width < 300 } &&
                retreatFrames.allSatisfy {
                    abs($0.maxX - 314) <= 1 && abs($0.height - 24) <= 1
            } &&
                abs((retreatFrames.last?.width ?? 0) - 28) <= 1 &&
                fixture.model.snapshot.visual(for: fixture.row).phase == .dragging,
            "disarming must contract the same right-anchored button back to finger tracking without "
                + "submitting; frames \(retreatFrames), phase "
                + "\(fixture.model.snapshot.visual(for: fixture.row).phase)"
        )
        fixture.model.inputRouter.cancel()
        let cancelled = try fixture.sampleActionBounds(until: { $0 == .zero })
        try motionExpect(
            cancelled.last == .zero && fixture.persistence.requests.isEmpty,
            "cancelling an armed gesture must restore the row without a write"
        )
    }

    private static func testNativeSwipeWriteFailure() throws {
        let fixture = try SwipeMotionFixture()
        defer { fixture.close() }
        fixture.beginDrag(distance: 65)
        _ = try fixture.sampleActionBounds(until: { abs($0.width - 308) <= 1 })
        fixture.model.inputRouter.change(translationX: -49, velocityX: 240)
        fixture.model.inputRouter.end(velocityX: 0)
        _ = try fixture.sampleActionBounds(until: { abs($0.width - 308) <= 1 })
        try motionExpect(
            fixture.persistence.requests == [fixture.request] &&
                fixture.model.snapshot.visual(for: fixture.row).isPending,
            "release inside armed hysteresis must submit exactly once and preserve pending feedback"
        )
        fixture.persistence.completion?(.failure(SwipeMotionTestError.writeFailed))
        let recovery = try fixture.sampleActionBounds(until: { abs($0.width - 44) <= 1 })
        try motionExpect(
            recovery.contains { $0.width > 50 && $0.width < 300 } &&
                recovery.allSatisfy { abs($0.maxX - 314) <= 1 } &&
                abs((recovery.last?.width ?? 0) - 44) <= 1 &&
                abs((recovery.last?.minX ?? 0) - 270) <= 1 &&
                fixture.model.snapshot.rows == [fixture.row] &&
                fixture.model.snapshot.visual(for: fixture.row).phase == .failed,
            "a failed full-swipe write must animate back to a retryable button without removing the row"
        )
    }

    private static func testNativeSwipeRemoval(captureProcessingDelay: TimeInterval) throws {
        let fixture = try SwipeMotionFixture()
        defer { fixture.close() }
        fixture.model.requestHide(fixture.row, rowWidth: 320)
        let committing = try fixture.sampleActionBounds(until: { abs($0.width - 308) <= 1 })
        try motionExpect(
            abs((committing.last?.width ?? 0) - 308) <= 1 &&
                fixture.model.snapshot.rows == [fixture.row] && fixture.model.scheduledWork.isEmpty,
            "a tapped HIDE should keep the row until its write succeeds"
        )
        var watchdog: DispatchWorkItem?
        let observation = fixture.model.$snapshot.sink { snapshot in
            let visual = snapshot.visual(for: fixture.row)
            guard !snapshot.rows.isEmpty, visual.phase == .removing, visual.height == 0,
                  fixture.model.scheduledWork.count == 1,
                  let pending = fixture.model.scheduledWork.values.first else {
                return
            }
            // Height-collapse publication leaves only the watchdog scheduled in this fixture.
            watchdog = pending
            pending.cancel()
        }
        defer { observation.cancel() }
        var removal = [try fixture.captureActionBounds()]
        fixture.captureProcessingDelay = captureProcessingDelay
        fixture.persistence.completion?(.success(SessionDismissalResponse(
            result: .dismissed,
            snapshot: SessionControllerSnapshot(
                revision: 2, sessions: [], reconciliationAnchor: nil, orderingKnown: true
            )
        )))
        removal += try fixture.sampleActionBounds(until: { bounds in
            bounds == .zero && fixture.model.snapshot.rows.isEmpty
        })
        try motionExpect(
            removal.contains { $0.width > 0 } && removal.last == .zero &&
                fixture.model.snapshot.rows.isEmpty && watchdog?.isCancelled == true &&
                fixture.model.scheduledWork.count == 1,
            "native removal must retire through its completion callback with the watchdog disabled; "
                + "frames \(removal), rows \(fixture.model.snapshot.rows.count), "
                + "watchdog disabled \(watchdog?.isCancelled == true)"
        )
    }

    private static func testNativeReducedMotionSwipe() throws {
        let fixture = try SwipeMotionFixture(reduceMotion: true)
        defer { fixture.close() }
        fixture.beginDrag(distance: 28)
        fixture.model.inputRouter.end(velocityX: 0)
        let settled = try fixture.sampleActionBounds()
        try motionExpect(
            settled.allSatisfy { abs($0.width - 44) <= 1 && abs($0.height - 24) <= 1 },
            "Reduce Motion must reach its open slot without intermediate spatial settling frames"
        )
        fixture.model.closeRevealedRow()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        fixture.beginDrag(distance: 63)
        fixture.model.inputRouter.change(translationX: -65, velocityX: -240)
        let frames = try fixture.sampleActionFrames()
        try motionExpect(
            frames.allSatisfy {
                abs($0.button.minX - 6) <= 1 && abs($0.button.width - 308) <= 1 &&
                    abs($0.button.height - 24) <= 1 && $0.label.width > 15 &&
                    abs($0.label.minX - $0.button.minX - 11) <= 2
            } &&
                fixture.persistence.requests.isEmpty,
            "Reduce Motion must retain armed feedback without an animated spatial expansion"
        )
    }

    private static func motionExpect(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw SwipeMotionTestError.expectation(message)
        }
    }
}
