import Foundation

extension MewsAppModelTests {
    static func testSessionPresentation() throws {
        try testActionableSessionOrdering()
        try testAcknowledgementOnlyReordersOwningSession()
        try testStaleAttentionDoesNotDemoteCompletion()
        try testSessionPresentationLimitsAndContexts()
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
                "done-new",
                "running",
                "idle",
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
                id: "idle",
                status: .idle,
                evidenceAt: now
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

    private static func testSessionPresentationLimitsAndContexts() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_300)
        let sessions = try (0..<6).map { index in
            try presentationSession(
                id: "session-\(index)",
                status: .running,
                evidenceAt: now.addingTimeInterval(TimeInterval(index))
            )
        }
        let presentation = SessionPresentationPolicy.resolve(
            sessions: sessions,
            attentionRecords: [],
            healthSnapshot: nil,
            now: now
        )
        let unavailable = try presentationSession(
            id: "unavailable",
            status: .needsInput,
            evidenceAt: now,
            actionable: false
        )
        let unavailablePresentation = SessionPresentationPolicy.resolve(
            sessions: [unavailable],
            attentionRecords: [],
            healthSnapshot: nil,
            now: now
        )
        let expiredPresentation = SessionPresentationPolicy.resolve(
            sessions: [
                try presentationSession(
                    id: "expired",
                    status: .idle,
                    evidenceAt: now.addingTimeInterval(-(24 * 60 * 60 + 1))
                )
            ],
            attentionRecords: [],
            healthSnapshot: nil,
            now: now
        )

        try presentationExpect(
            presentation.panelRows.count == 3 && presentation.menuRows.count == 5,
            "the panel and menu should remain explicitly bounded"
        )
        try presentationExpect(
            unavailablePresentation.rows.first?.returnContext == nil,
            "invalid return metadata should keep the session action disabled"
        )
        try presentationExpect(
            expiredPresentation.rows.isEmpty,
            "the recent-session surface should not retain evidence older than 24 hours"
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
            previous: previous.panelRows
        )
        let removed = SessionPresentationPolicy.stabilizedRows(
            canonical: [],
            previous: previous.panelRows
        )

        try presentationExpect(
            stabilized.map(\.identity.sessionID) == ["first", "second", "urgent"],
            "expanded content should retain visible row order until collapse"
        )
        try presentationExpect(
            removed.allSatisfy { $0.returnContext == nil },
            "a removed session may retain its slot but must not retain stale actions"
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
        status: SessionStatus,
        evidenceAt: Date,
        project: String? = "Mews",
        actionable: Bool = true
    ) throws -> CurrentSessionState {
        let identity = try presentationRequire(
            SessionIdentity(source: "copilot", sessionID: id),
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
            evidenceStatus: status,
            statusChangedAt: evidenceAt,
            evidenceAt: evidenceAt,
            project: project,
            hookEvent: nil,
            returnContext: returnContext,
            isFresh: true
        )
    }

    private static func presentationAttention(
        session: CurrentSessionState,
        disposition: AttentionDisposition
    ) throws -> AttentionRecord {
        let key = try presentationRequire(
            AttentionKey(
                identity: session.identity,
                status: session.status,
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
