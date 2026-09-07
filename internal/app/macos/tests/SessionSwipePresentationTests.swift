import Foundation

extension MewsAppModelTests {
    static func testSessionSwipePresentation() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_800)
        let stopped = try swipePresentationSession(
            id: "stopped",
            status: .done,
            evidenceAt: now,
            evidenceID: "stopped-evidence",
            orderingKnown: true
        )
        let running = try swipePresentationSession(
            id: "running-swipe",
            status: .running,
            evidenceAt: now,
            evidenceID: "running-evidence",
            orderingKnown: true
        )
        let unresolved = try swipePresentationSession(
            id: "unresolved",
            status: .done,
            evidenceAt: now,
            evidenceID: "unresolved-evidence",
            orderingKnown: false
        )
        let presentation = SessionPresentationPolicy.resolve(
            sessions: [stopped, running, unresolved],
            attentionRecords: [],
            healthSnapshot: nil,
            now: now,
            sessionRevision: 7
        )
        try assertSwipePresentation(
            presentation,
            stopped: stopped,
            running: running,
            unresolved: unresolved
        )
        try assertFullSwipePresentation()
    }

    private static func assertFullSwipePresentation() throws {
        try assertFullWidthSwipe()
        try assertCompactSwipe()
        try assertExpandingSwipe()
        try assertLatchedSwipe()
        try assertRemovingSwipe()
    }

    private static func assertFullWidthSwipe() throws {
        let fullSwipe = SessionSwipeRowVisual(
            phase: .commitReady,
            offset: -65,
            opacity: 1,
            height: 42,
            isPending: false
        )
        try swipePresentationExpect(
            fullSwipe.contentOffset(rowWidth: 320) == -320 &&
                fullSwipe.actionWidth(rowWidth: 320) == 308 &&
                fullSwipe.actionHeight(rowWidth: 320) == 24 &&
                fullSwipe.actionCornerRadius(rowWidth: 320) == 4 &&
                fullSwipe.actionVerticalOffset(rowWidth: 320) == -2 &&
                fullSwipe.usesFullWidthAction(rowWidth: 320),
            "commit-ready should stretch HIDE across the inset track at the shared button height"
        )
    }

    private static func assertCompactSwipe() throws {
        let initial = swipeVisual(phase: .dragging, offset: -28)
        try swipePresentationExpect(
            initial.actionWidth(rowWidth: 320) == 16 &&
                initial.actionHeight(rowWidth: 320) == 16 &&
                initial.actionCornerRadius(rowWidth: 320) == 8,
            "the first visible part of HIDE must have equal width and height, not an oval"
        )
        let shortSwipe = swipeVisual(phase: .revealed, offset: -56)
        try swipePresentationExpect(
            shortSwipe.actionWidth(rowWidth: 320) == 44 &&
                shortSwipe.contentOffset(rowWidth: 320) == -56 &&
                shortSwipe.actionHeight(rowWidth: 320) == 24 &&
                shortSwipe.actionCornerRadius(rowWidth: 320) == 4 &&
                shortSwipe.actionVerticalOffset(rowWidth: 320) == -2 &&
                !shortSwipe.usesFullWidthAction(rowWidth: 320) &&
                shortSwipe.acceptsSwipeInput,
            "a short swipe should reveal a COPY-sized HIDE button"
        )
    }

    private static func assertExpandingSwipe() throws {
        let visual = swipeVisual(phase: .dragging, offset: -63)
        try swipePresentationExpect(
            visual.actionWidth(rowWidth: 320) == 51 &&
                visual.contentOffset(rowWidth: 320) == -63 &&
                visual.actionHeight(rowWidth: 320) == 24 &&
                visual.actionCornerRadius(rowWidth: 320) == 4,
            "before twenty percent, HIDE should follow the exposed width without growing taller"
        )
    }

    private static func assertLatchedSwipe() throws {
        for phase in [SessionSwipePhase.commitReady, .committing] {
            let visual = swipeVisual(phase: phase, offset: -49)
            try swipePresentationExpect(
                visual.actionWidth(rowWidth: 320) == 308 &&
                    visual.actionHeight(rowWidth: 320) == 24 &&
                    visual.usesFullWidthAction(rowWidth: 320),
                "full-swipe feedback must stay expanded throughout the armed retreat band and release"
            )
        }
        let disarmed = swipeVisual(phase: .dragging, offset: -47)
        try swipePresentationExpect(
            disarmed.actionWidth(rowWidth: 320) == 35 &&
                disarmed.contentOffset(rowWidth: 320) == -47 &&
                disarmed.actionHeight(rowWidth: 320) == 24,
            "retreat past hysteresis should return to the exposed button without submitting"
        )
    }

    private static func assertRemovingSwipe() throws {
        let removing = SessionSwipeRowVisual(
            phase: .removing,
            offset: -320,
            opacity: 0,
            height: 0,
            isPending: false
        )
        try swipePresentationExpect(
            !removing.acceptsSwipeInput,
            "a leaving row should not retain an input target"
        )
    }

    private static func swipeVisual(
        phase: SessionSwipePhase,
        offset: CGFloat
    ) -> SessionSwipeRowVisual {
        return SessionSwipeRowVisual(
            phase: phase,
            offset: offset,
            opacity: 1,
            height: 42,
            isPending: false
        )
    }

    private static func assertSwipePresentation(
        _ presentation: SessionPresentation,
        stopped: CurrentSessionState,
        running: CurrentSessionState,
        unresolved: CurrentSessionState
    ) throws {
        try swipePresentationExpect(
            presentation.sessionRevision == 7,
            "presentation should carry the session revision into the swipe layer"
        )
        try swipePresentationExpect(
            presentation.rows.first(where: {
                $0.identity == stopped.identity
            })?.dismissalRequest == SessionDismissalRequest(
                identity: stopped.identity,
                evidenceID: stopped.evidenceID
            ),
            "an ordered STOP row should expose an evidence-scoped hide target"
        )
        try swipePresentationExpect(
            presentation.rows.first(where: {
                $0.identity == running.identity
            })?.dismissalRequest == nil &&
                presentation.rows.first(where: {
                    $0.identity == unresolved.identity
                })?.dismissalRequest == nil,
            "running and ordering-unknown rows should not expose swipe actions"
        )
    }

    private static func swipePresentationSession(
        id: String,
        status: SessionStatus,
        evidenceAt: Date,
        evidenceID: String,
        orderingKnown: Bool
    ) throws -> CurrentSessionState {
        guard let identity = SessionIdentity(source: "copilot", sessionID: id) else {
            throw SessionSwipePresentationTestError.invalidFixture
        }
        return CurrentSessionState(
            identity: identity,
            status: status,
            evidenceStatus: status,
            statusChangedAt: evidenceAt,
            evidenceAt: evidenceAt,
            project: "Mews",
            hookEvent: "agentStop",
            returnContext: nil,
            isFresh: true,
            evidenceID: evidenceID,
            orderingKnown: orderingKnown
        )
    }

    private static func swipePresentationExpect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw SessionSwipePresentationTestError.expectation(message)
        }
    }
}

private enum SessionSwipePresentationTestError: Error {
    case invalidFixture
    case expectation(String)
}
