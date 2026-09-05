import Foundation

extension MewsAppModelTests {
    static func testDismissalFreshnessBoundaries() throws {
        let now = Date(timeIntervalSince1970: 1_900_001_900)
        for boundary in dismissalBoundaryCases() {
            try assertDismissalBoundary(boundary, now: now)
        }
        try testAmbiguousTerminalSlot()
        try testNoSlotDismissalFiltering(now: now)
    }

    private static func dismissalBoundaryCases() -> [DismissalBoundaryCase] {
        return [
            DismissalBoundaryCase(
                name: "unknown-29-minutes",
                source: "codex",
                age: 29 * 60,
                expected: .dismissed
            ),
            DismissalBoundaryCase(
                name: "unknown-30-minutes",
                source: "codex",
                age: 30 * 60,
                expected: .dismissed
            ),
            DismissalBoundaryCase(
                name: "unknown-31-minutes",
                source: "codex",
                age: 31 * 60,
                expected: .ineligibleState
            ),
            DismissalBoundaryCase(
                name: "open-23-hours-59-minutes",
                source: "copilot",
                age: 23 * 60 * 60 + 59 * 60,
                expected: .dismissed
            ),
            DismissalBoundaryCase(
                name: "open-24-hours",
                source: "copilot",
                age: 24 * 60 * 60,
                expected: .dismissed
            ),
            DismissalBoundaryCase(
                name: "open-24-hours-1-minute",
                source: "copilot",
                age: 24 * 60 * 60 + 60,
                expected: .ineligibleState
            )
        ]
    }

    private static func assertDismissalBoundary(
        _ boundary: DismissalBoundaryCase,
        now: Date
    ) throws {
        let event = try sessionEvent(
            id: boundary.name,
            source: boundary.source,
            sessionID: boundary.name,
            status: "done",
            hookEvent: "agentStop",
            timestamp: now.addingTimeInterval(-boundary.age)
        )
        var index = SessionStateIndex.rebuilding(from: [event], now: now)
        try sessionExpect(
            index.dismiss(dismissalRequest(for: event), now: now) == boundary.expected,
            "unexpected dismissal eligibility at \(boundary.name)"
        )
    }

    private static func testAmbiguousTerminalSlot() throws {
        let now = Date(timeIntervalSince1970: 1_900_001_950)
        let events = try terminalSlotDismissalEvents(now: now)
        let rebuilt = SessionStateIndex.rebuilding(from: events, now: now)
        var records = rebuilt.persistedRecords
        records[0] = records[0].withUnknownOrdering()
        var ambiguous = try SessionStateIndex(restoring: records)
        let sessions = ambiguous.currentSessions(now: now)
        let known = try sessionRequire(
            sessions.first { $0.orderingKnown },
            "one terminal-slot candidate should retain known ordering"
        )
        try sessionExpect(
            ambiguous.dismiss(
                SessionDismissalRequest(
                    identity: known.identity,
                    evidenceID: known.evidenceID
                ),
                now: now
            ) == .orderingUnavailable,
            "an ambiguous highest terminal-slot tie should reject dismissal"
        )
        try sessionExpect(
            SessionPresentationPolicy.resolve(
                sessions: sessions,
                attentionRecords: [],
                healthSnapshot: nil,
                now: now
            ).rows.count == 2,
            "ambiguous terminal-slot winners should remain visible"
        )
    }

    private static func testNoSlotDismissalFiltering(now: Date) throws {
        let event = try sessionEvent(
            id: "dismissal-no-slot",
            sessionID: "dismissal-no-slot",
            status: "done",
            hookEvent: "agentStop",
            timestamp: now
        )
        var index = SessionStateIndex.rebuilding(from: [event], now: now)
        try sessionExpect(
            index.dismiss(dismissalRequest(for: event), now: now) == .dismissed,
            "a visible STOP without terminal metadata should be dismissible"
        )
        try sessionExpect(
            SessionPresentationPolicy.resolve(
                sessions: index.currentSessions(now: now),
                attentionRecords: [],
                healthSnapshot: nil,
                now: now
            ).rows.isEmpty,
            "dismissal filtering should also apply without a terminal slot"
        )
    }
}

private struct DismissalBoundaryCase {
    let name: String
    let source: String
    let age: TimeInterval
    let expected: SessionDismissalResult
}
