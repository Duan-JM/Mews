import Foundation

extension MewsAppModelTests {
    static func testSessionPresentation() throws {
        try testActionableSessionOrdering()
        try testAcknowledgementOnlyReordersOwningSession()
        try testStaleAttentionDoesNotDemoteCompletion()
        try testConfirmedHealthPresentation()
        try testExpandedSessionOrderStability()
        try testSessionAccessibilityCopy()
    }

    private static func testActionableSessionOrdering() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let sessions = try presentationOrderingSessions(now: now)
        let acknowledgedDone = try presentationRequire(
            sessions.first { $0.sessionID == "done-ack" },
            "acknowledged completion fixture should exist"
        )
        let presentation = SessionPresentationPolicy.resolve(
            sessions: sessions,
            attentionRecords: [
                try presentationAttention(
                    session: acknowledgedDone,
                    disposition: .acknowledged
                )
            ],
            healthSnapshot: nil,
            now: now
        )

        try presentationExpect(
            presentation.rows.map(\.identity.sessionID) == [
                "needs-input",
                "failed",
                "running",
                "done-new",
                "done-ack"
            ],
            "sessions should sort by actionability before recency"
        )
    }

    private static func presentationOrderingSessions(
        now: Date
    ) throws -> [CurrentSessionState] {
        return [
            try presentationSession(
                id: "closed",
                status: .idle,
                evidenceAt: now,
                hookEvent: "sessionEnd"
            ),
            try presentationSession(
                id: "running",
                status: .running,
                evidenceAt: now.addingTimeInterval(-20)
            ),
            try presentationSession(
                id: "done-new",
                status: .done,
                evidenceAt: now.addingTimeInterval(-30)
            ),
            try presentationSession(
                id: "failed",
                status: .failed,
                evidenceAt: now.addingTimeInterval(-40)
            ),
            try presentationSession(
                id: "done-ack",
                status: .done,
                evidenceAt: now.addingTimeInterval(-10)
            ),
            try presentationSession(
                id: "needs-input",
                status: .needsInput,
                evidenceAt: now.addingTimeInterval(-50)
            )
        ]
    }

    private static func testAcknowledgementOnlyReordersOwningSession() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_100)
        let first = try presentationSession(
            id: "first",
            status: .done,
            evidenceAt: now
        )
        let second = try presentationSession(
            id: "second",
            status: .done,
            evidenceAt: now.addingTimeInterval(-1)
        )
        let records = [
            try presentationAttention(session: first, disposition: .acknowledged),
            try presentationAttention(session: second, disposition: .delivered)
        ]
        let presentation = SessionPresentationPolicy.resolve(
            sessions: [first, second],
            attentionRecords: records,
            healthSnapshot: nil,
            now: now
        )

        try presentationExpect(
            presentation.rows.map(\.identity.sessionID) == ["second", "first"],
            "acknowledging one done session should leave the other session actionable"
        )
        try presentationExpect(
            presentation.rows[0].returnCommand?.contains("second") == true &&
                presentation.rows[1].returnCommand?.contains("first") == true,
            "parallel sessions should retain distinct return commands"
        )
    }

    private static func testStaleAttentionDoesNotDemoteCompletion() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_200)
        let session = try presentationSession(
            id: "new-round",
            status: .done,
            evidenceAt: now
        )
        let staleKey = try presentationRequire(
            AttentionKey(
                identity: session.identity,
                status: .done,
                statusChangedAt: now.addingTimeInterval(-60)
            ),
            "stale attention key should be valid"
        )
        let stale = AttentionRecord(
            identity: session.identity,
            key: staleKey,
            disposition: .acknowledged
        )
        let presentation = SessionPresentationPolicy.resolve(
            sessions: [session],
            attentionRecords: [stale],
            healthSnapshot: nil,
            now: now
        )

        try presentationExpect(
            presentation.rows.first?.priority == .unacknowledgedDone,
            "an acknowledged older round must not demote a newer completion"
        )
    }

    private static func testConfirmedHealthPresentation() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_400)
        let snapshot = RuntimeHealthSnapshot(
            version: 1,
            state: .blocked,
            summary: "Attention required",
            checkedAt: now,
            validUntil: now.addingTimeInterval(30),
            capabilities: [
                presentationCapability(
                    id: "notifications",
                    name: "Notifications",
                    state: .degraded,
                    message: "Delivery delayed"
                ),
                presentationCapability(
                    id: "socket",
                    name: "Event delivery",
                    state: .blocked,
                    message: "Socket unavailable",
                    recovery: "mw doctor"
                )
            ]
        )
        let presentation = SessionPresentationPolicy.resolve(
            sessions: [],
            attentionRecords: [],
            healthSnapshot: snapshot,
            now: now
        )
        let stale = SessionPresentationPolicy.resolve(
            sessions: [],
            attentionRecords: [],
            healthSnapshot: snapshot,
            now: now.addingTimeInterval(31)
        )

        try presentationExpect(
            presentation.health?.capabilityID == "socket" &&
                presentation.health?.additionalCount == 1,
            "confirmed blockers should lead and disclose additional affected capabilities"
        )
        try presentationExpect(
            stale.health == nil,
            "expired health evidence should not remain a user-visible blocker"
        )
    }

    private static func testExpandedSessionOrderStability() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_500)
        let first = try presentationSession(
            id: "first",
            status: .running,
            evidenceAt: now
        )
        let second = try presentationSession(
            id: "second",
            status: .running,
            evidenceAt: now.addingTimeInterval(-1)
        )
        let urgent = try presentationSession(
            id: "urgent",
            status: .needsInput,
            evidenceAt: now.addingTimeInterval(1)
        )
        let previous = SessionPresentationPolicy.resolve(
            sessions: [first, second],
            attentionRecords: [],
            healthSnapshot: nil,
            now: now
        )
        let canonical = SessionPresentationPolicy.resolve(
            sessions: [urgent, first, second],
            attentionRecords: [],
            healthSnapshot: nil,
            now: now
        )
        let stabilized = SessionPresentationPolicy.stabilizedRows(
            canonical: canonical.rows,
            previous: previous.rows
        )
        let removed = SessionPresentationPolicy.stabilizedRows(
            canonical: [],
            previous: previous.rows
        )

        try presentationExpect(
            stabilized.map(\.identity.sessionID) == ["first", "second", "urgent"],
            "expanded content should retain visible row order until collapse"
        )
        try presentationExpect(
            removed.isEmpty,
            "an explicitly removed session should leave the expanded list immediately"
        )
    }

    private static func testSessionAccessibilityCopy() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_600)
        let session = try presentationSession(
            id: "session-1234567890-private",
            status: .needsInput,
            evidenceAt: now,
            project: "/Users/example/SecretProject"
        )
        let row = try presentationRequire(
            SessionPresentationPolicy.resolve(
                sessions: [session],
                attentionRecords: [],
                healthSnapshot: nil,
                now: now
            ).rows.first,
            "presentation row should exist"
        )

        try presentationExpect(
            row.accessibilityLabel.contains("12345678") &&
                !row.accessibilityLabel.contains(session.sessionID) &&
                !row.accessibilityLabel.contains("/Users/example"),
            "accessibility copy should identify the session without exposing full local metadata"
        )
        try presentationExpect(
            notchDisplayColumnCount(row.primaryLabel) <= 30 &&
                !row.primaryLabel.contains("…"),
            "the fixed session identity slot should hard-bound text without an ellipsis"
        )
    }

    private static func presentationSession(
        id: String,
        source: String = "copilot",
        status: SessionStatus,
        evidenceStatus: SessionStatus? = nil,
        evidenceAt: Date,
        project: String? = "Mews",
        actionable: Bool = true,
        hookEvent: String? = "testLifecycle",
        isFresh: Bool = true
    ) throws -> CurrentSessionState {
        let identity = try presentationRequire(
            SessionIdentity(source: source, sessionID: id),
            "session identity should be valid"
        )
        let returnContext = actionable
            ? CLIContextPayload(
                returnCommand: "mw history --session '\(id)'",
                workingDirectory: "/tmp"
            )
            : nil
        return CurrentSessionState(
            identity: identity,
            status: status,
            evidenceStatus: evidenceStatus ?? status,
            statusChangedAt: evidenceAt,
            evidenceAt: evidenceAt,
            project: project,
            hookEvent: hookEvent,
            returnContext: returnContext,
            isFresh: isFresh
        )
    }

    private static func presentationAttention(
        session: CurrentSessionState,
        disposition: AttentionDisposition
    ) throws -> AttentionRecord {
        let key = try presentationRequire(
            AttentionKey(
                identity: session.identity,
                status: session.presentationStatus,
                statusChangedAt: session.statusChangedAt
            ),
            "attention key should be valid"
        )
        return AttentionRecord(
            identity: session.identity,
            key: key,
            disposition: disposition
        )
    }

    private static func presentationCapability(
        id: String,
        name: String,
        state: RuntimeHealthState,
        message: String,
        recovery: String? = nil
    ) -> RuntimeHealthCapability {
        return RuntimeHealthCapability(
            id: id,
            name: name,
            kind: .functional,
            state: state,
            message: message,
            recovery: recovery,
            transitionFrom: nil,
            transitionTarget: nil,
            transitionCount: nil
        )
    }

    private static func presentationExpect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw SessionPresentationTestFailure(message: message)
        }
    }

    private static func presentationRequire<T>(
        _ value: T?,
        _ message: String
    ) throws -> T {
        guard let value else {
            throw SessionPresentationTestFailure(message: message)
        }
        return value
    }
}

private struct SessionPresentationTestFailure: Error {
    let message: String
}
