import Foundation

extension MewsAppModelTests {
    static func testSessionSwipeInteraction() throws {
        try testSwipeAxisLock()
        try testSwipeDeltaNormalization()
        try testSwipeAnimationVelocity()
        try testSwipeShortSettleTargets()
        try testSwipeRevealedCloseThreshold()
        try testSwipeCancellationRestoresOrigin()
        try testSwipeCommitThresholdAndHysteresis()
        try testSwipeExplicitCommitAndFailure()
    }

    private static func testSwipeAxisLock() throws {
        var horizontal = SessionSwipeAxisLock()
        try swipeExpect(
            horizontal.update(deltaX: -6, deltaY: 1) == .pending,
            "input should remain undecided inside the eight-point slop"
        )
        try swipeExpect(
            horizontal.update(deltaX: -3, deltaY: 1) == .horizontal,
            "predominantly horizontal movement should lock after the slop"
        )
        _ = horizontal.update(deltaX: -12, deltaY: 2)
        try swipeExpect(
            horizontal.translationX == -21 && horizontal.translationY == 4,
            "locked input should keep accumulating the full gesture translation"
        )

        var vertical = SessionSwipeAxisLock()
        try swipeExpect(
            vertical.update(deltaX: -4, deltaY: 8) == .vertical,
            "diagonal movement below the horizontal ratio should become native scrolling"
        )
        try swipeExpect(
            vertical.update(deltaX: -20, deltaY: 0) == .vertical,
            "the selected axis should remain irreversible for the gesture"
        )
    }

    private static func testSwipeDeltaNormalization() throws {
        try swipeExpect(
            SessionSwipeDelta.physical(
                x: -3,
                y: 5,
                isDirectionInvertedFromDevice: false
            ) == CGPoint(x: -3, y: 5),
            "legacy scrolling should preserve physical deltas"
        )
        try swipeExpect(
            SessionSwipeDelta.physical(
                x: 3,
                y: -5,
                isDirectionInvertedFromDevice: true
            ) == CGPoint(x: -3, y: 5),
            "natural scrolling should normalize to the same physical gesture direction"
        )
    }

    private static func testSwipeAnimationVelocity() throws {
        try swipeExpect(
            SessionSwipeAnimationPhysics.normalizedVelocity(
                velocityX: -640,
                from: -176,
                to: -320
            ) == 4,
            "leftward release velocity should continue toward a leftward removal target"
        )
        try swipeExpect(
            SessionSwipeAnimationPhysics.normalizedVelocity(
                velocityX: -80,
                from: -32,
                to: 0
            ) == -2.5,
            "velocity away from a close target should preserve its signed spring handoff"
        )
    }

    private static func testSwipeShortSettleTargets() throws {
        let target = try swipeTarget(id: "short")
        var interaction = SessionSwipeInteraction()
        interaction.begin(target: target, rowWidth: 320)
        _ = interaction.update(translationX: -7)
        try swipeExpect(
            interaction.end(velocityX: 0) == .closed &&
                interaction.phase == .resting &&
                interaction.offset == 0,
            "movement below the eight-point input slop should close"
        )

        interaction.begin(target: target, rowWidth: 320)
        _ = interaction.update(translationX: -8)
        try swipeExpect(
            interaction.end(velocityX: 0) == .revealed &&
                interaction.phase == .revealed &&
                interaction.offset == -63,
            "a deliberate short swipe should leave room for HIDE, its insets, and the gutter"
        )
        interaction.reset()
        interaction.begin(target: target, rowWidth: 640)
        _ = interaction.update(translationX: -100)
        try swipeExpect(
            interaction.end(velocityX: 0) == .revealed && interaction.offset == -64,
            "a wider row should settle at ten percent when that fits the button"
        )
    }

    private static func testSwipeRevealedCloseThreshold() throws {
        let target = try swipeTarget(id: "revealed")
        var interaction = SessionSwipeInteraction()
        interaction.begin(target: target, rowWidth: 320)
        _ = interaction.update(translationX: -40)
        _ = interaction.end(velocityX: 0)

        interaction.begin(target: target, rowWidth: 320)
        _ = interaction.update(translationX: 23)
        try swipeExpect(
            interaction.end(velocityX: 0) == .revealed,
            "a revealed row should remain open below the 24-point close threshold"
        )

        interaction.begin(target: target, rowWidth: 320)
        _ = interaction.update(translationX: 25)
        try swipeExpect(
            interaction.end(velocityX: 0) == .closed,
            "a revealed row should close after a right drag beyond 24 points"
        )
    }

    private static func testSwipeCancellationRestoresOrigin() throws {
        let target = try swipeTarget(id: "cancel")
        var interaction = SessionSwipeInteraction()
        interaction.begin(target: target, rowWidth: 320)
        _ = interaction.update(translationX: -50)
        try swipeExpect(
            interaction.cancel() == .closed &&
                interaction.phase == .resting,
            "cancelling a new swipe should restore the resting position"
        )

        interaction.begin(target: target, rowWidth: 320)
        _ = interaction.update(translationX: -50)
        _ = interaction.end(velocityX: 0)
        interaction.begin(target: target, rowWidth: 320)
        _ = interaction.update(translationX: -30)
        try swipeExpect(
            interaction.cancel() == .revealed &&
                interaction.phase == .revealed &&
                interaction.offset == -63,
            "cancelling a resumed swipe should restore its revealed origin"
        )
    }

    private static func testSwipeCommitThresholdAndHysteresis() throws {
        let target = try swipeTarget(id: "commit")
        var interaction = SessionSwipeInteraction()
        interaction.begin(target: target, rowWidth: 320)
        try swipeExpect(
            !interaction.update(translationX: -64) && interaction.phase == .dragging,
            "reaching exactly twenty percent should not arm a full swipe"
        )
        try swipeExpect(
            interaction.update(translationX: -65),
            "crossing twenty percent should request haptic feedback"
        )
        try swipeExpect(
            interaction.phase == .commitReady &&
                !interaction.update(translationX: -68),
            "remaining beyond the threshold should not repeat haptic feedback"
        )
        _ = interaction.update(translationX: -49)
        try swipeExpect(
            interaction.phase == .commitReady,
            "the 16-point hysteresis should retain commit readiness"
        )
        _ = interaction.update(translationX: -47)
        try swipeExpect(
            interaction.phase == .dragging,
            "retreating beyond the hysteresis should cancel commit readiness"
        )
        try swipeExpect(
            !interaction.update(translationX: -68),
            "re-entering commit readiness in one gesture should not repeat haptics"
        )
        try swipeExpect(
            interaction.end(velocityX: -640) == .commit(target, velocityX: -640),
            "a full swipe should commit only when the gesture ends"
        )
    }

    private static func testSwipeExplicitCommitAndFailure() throws {
        let target = try swipeTarget(id: "button")
        var interaction = SessionSwipeInteraction()
        interaction.begin(target: target, rowWidth: 320)
        _ = interaction.update(translationX: -50)
        _ = interaction.end(velocityX: 0)
        try swipeExpect(
            interaction.requestCommit() == .commit(target, velocityX: 0),
            "the revealed HIDE action should use the same commit path"
        )
        interaction.markFailed()
        try swipeExpect(
            interaction.phase == .failed && interaction.offset == -63,
            "a failed commit should return to the revealed position"
        )
        try swipeExpect(
            interaction.requestCommit() == .commit(target, velocityX: 0),
            "a failed commit should remain retryable"
        )
        interaction.markRemoving()
        try swipeExpect(
            interaction.phase == .removing,
            "a persisted dismissal should advance to removal"
        )
    }

    private static func swipeTarget(id: String) throws -> SessionDismissalRequest {
        guard let identity = SessionIdentity(source: "codex", sessionID: id) else {
            throw SessionSwipeTestFailure(message: "swipe identity should be valid")
        }
        return SessionDismissalRequest(identity: identity, evidenceID: "evidence-\(id)")
    }

    private static func swipeExpect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw SessionSwipeTestFailure(message: message)
        }
    }
}

private struct SessionSwipeTestFailure: Error {
    let message: String
}
