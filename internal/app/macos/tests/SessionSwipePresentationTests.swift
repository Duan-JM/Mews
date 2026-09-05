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
        let fullSwipe = SessionSwipeRowVisual(
            phase: .commitReady,
            offset: -176,
            opacity: 1,
            height: 42,
            isPending: false
        )
        let shortSwipe = SessionSwipeRowVisual(
            phase: .revealed,
            offset: -72,
            opacity: 1,
            height: 42,
            isPending: false
        )
        try swipePresentationExpect(
            fullSwipe.actionWidth(rowWidth: 320) == 320 &&
                fullSwipe.usesFullWidthAction,
            "commit-ready feedback should expand the red action across the row"
        )
        try swipePresentationExpect(
            shortSwipe.actionWidth(rowWidth: 320) == 72 &&
                !shortSwipe.usesFullWidthAction &&
                shortSwipe.acceptsSwipeInput,
            "a short swipe should keep the action at its revealed width"
        )
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
