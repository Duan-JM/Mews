import Foundation

extension MewsAppModelTests {
    static func testNotchPanelContent() throws {
        try testPrimaryHistoryFiltering()
        try testPanelDisplaySafety()
        try testSensitiveCopyRedaction()
        try testPanelActionAvailability()
        try testExpiredCurrentEvent()
        try testUnscopedSessionHistory()
        try testExpandedContentStability()
        try testExpiredExpandedAction()
    }

    private static func testPrimaryHistoryFiltering() throws {
        let events = try [
            panelEvent(["id": "running", "status": "running", "message": "Working"]),
            panelEvent([
                "id": "subagent",
                "status": "done",
                "agent_scope": "subagent",
                "message": "Subagent done"
            ]),
            panelEvent([
                "id": "recoverable",
                "status": "failed",
                "recoverable": true,
                "message": "Recoverable failure"
            ]),
            panelEvent(["id": "input", "status": "needs_input", "message": "Waiting"]),
            panelEvent(["id": "done", "status": "done", "message": "Finished"])
        ]
        let content = NotchPanelContent(events: events)

        try panelExpect(content.current?.statusLabel == "Done", "latest primary event should be current")
        try panelExpect(
            content.recent.map(\.statusLabel) == ["Needs Input", "Running"],
            "recent history should exclude subagent and recoverable events"
        )

        let cappedEvents = try (0..<6).map { index in
            try panelEvent([
                "id": "event-\(index)",
                "status": index.isMultiple(of: 2) ? "running" : "done",
                "message": "Event \(index)"
            ])
        }
        try panelExpect(
            NotchPanelContent(events: cappedEvents).recent.count == 3,
            "expanded history should contain at most three earlier primary events"
        )
    }

    private static func testPanelDisplaySafety() throws {
        let longProject = String(repeating: "项目", count: 20) + "\nprivate"
        let fullSession = "session-1234567890-secret"
        let event = try panelEvent([
            "source": "custom\nsource",
            "status": "done",
            "project": longProject,
            "session_id": fullSession,
            "task_title": "  First\nline\twith\u{0007}\u{202E}   compact spacing  ",
            "message": "raw message"
        ])
        let summary = try panelRequire(
            NotchPanelContent(events: [event]).current,
            "panel summary should exist"
        )

        try panelExpect(summary.sourceLabel == "custom source", "source should be normalized to one line")
        try panelExpect(summary.sessionLabel == "12345678", "session display should remove a generic prefix")
        try panelExpect(
            summary.metadataLine?.contains(fullSession) == false,
            "metadata should not expose the full session identifier"
        )
        try panelExpect(
            !summary.message.contains("\n") && summary.message == "First line with compact spacing",
            "opted-in task titles should be compacted to one line"
        )
        try panelExpect(
            notchDisplayColumnCount(summary.projectLabel ?? "") <= 26,
            "project display should stay within its fixed column budget"
        )

    }

    private static func testSensitiveCopyRedaction() throws {
        let pathEvent = try panelEvent([
            "status": "failed",
            "project": "/Users/example/SecretProject",
            "message": "Failed at /Users/example/SecretProject/file.swift"
        ])
        let pathSummary = try panelRequire(
            NotchPanelContent(events: [pathEvent]).current,
            "path summary should exist"
        )
        try panelExpect(
            pathSummary.projectLabel == "SecretProject" &&
                pathSummary.message == "Failed at [path]",
            "panel copy should not expose an absolute working path"
        )

        let runner = try panelEvent([
            "source": "runner",
            "status": "done",
            "message": "rm -rf /private/project"
        ])
        let runnerSummary = try panelRequire(
            NotchPanelContent(events: [runner]).current,
            "runner summary should exist"
        )
        try panelExpect(
            runnerSummary.message == "Command finished",
            "runner command text should not be rendered in the panel"
        )
    }

    private static func testPanelActionAvailability() throws {
        let actionable = try panelEvent([
            "session_id": "session-1",
            "status": "done",
            "cwd": "/tmp"
        ])
        let actionableContent = NotchPanelContent(events: [actionable])
        try panelExpect(
            actionableContent.actionableContext != nil,
            "validated current context should enable Return to CLI"
        )
        try panelExpect(
            actionableContent.returnCommand?.contains("session-1") == true,
            "a session context should expose the Mews-owned copy command"
        )

        let invalid = try panelEvent([
            "session_id": "",
            "status": "failed",
            "cwd": "relative/private/path"
        ])
        let invalidContent = NotchPanelContent(events: [invalid])
        try panelExpect(
            invalidContent.actionableContext == nil && invalidContent.returnCommand == nil,
            "invalid context should leave both panel actions disabled"
        )
    }

    private static func testExpiredCurrentEvent() throws {
        let stale = try panelEvent([
            "id": "stale-done",
            "session_id": "session-stale",
            "status": "done",
            "cwd": "/tmp"
        ])
        let content = NotchPanelContent(
            events: [stale],
            currentEvent: nil
        )

        try panelExpect(content.current == nil, "expired state should not remain the current summary")
        try panelExpect(
            content.recent.map(\.statusLabel) == ["Done"],
            "expired state should remain available in bounded local history"
        )
        try panelExpect(
            content.actionableContext == nil,
            "expired state should not keep current-context actions enabled"
        )
    }

    private static func testUnscopedSessionHistory() throws {
        let row = try panelSessionRow(
            id: "stable-session",
            status: .running,
            evidenceAt: Date(timeIntervalSince1970: 1_900_001_000)
        )
        let scoped = try panelEvent([
            "id": "scoped",
            "session_id": "stable-session",
            "message": "Scoped event"
        ])
        let unscoped = try panelEvent([
            "id": "unscoped",
            "session_id": "",
            "status": "done",
            "message": "History-only event"
        ])
        let content = NotchPanelContent(
            presentation: SessionPresentation(rows: [row], health: nil),
            events: [scoped, unscoped],
            currentEvent: scoped
        )

        try panelExpect(
            content.visibleSessionRows.map(\.identity.sessionID) == ["stable-session"],
            "stable sessions should render as actionable rows"
        )
        try panelExpect(
            content.visibleRecent.count == 1 &&
                content.visibleRecent.first?.sessionLabel == nil,
            "events without stable identity should remain bounded history"
        )
    }

    private static func testExpandedContentStability() throws {
        let first = try panelSessionRow(
            id: "first",
            status: .running,
            evidenceAt: Date(timeIntervalSince1970: 1_900_001_100)
        )
        let second = try panelSessionRow(
            id: "second",
            status: .running,
            evidenceAt: Date(timeIntervalSince1970: 1_900_001_099)
        )
        let urgent = try panelSessionRow(
            id: "urgent",
            status: .needsInput,
            evidenceAt: Date(timeIntervalSince1970: 1_900_001_101)
        )
        let previous = panelContent(
            rows: [first, second],
            health: panelHealth(id: "prior", state: .degraded)
        )
        let canonical = panelContent(
            rows: [urgent, second, first],
            health: panelHealth(
                id: "next",
                state: .blocked,
                recovery: "mw doctor"
            )
        )
        let stabilized = canonical.stabilized(relativeTo: previous)

        try panelExpect(
            stabilized.visibleSessionRows.map(\.identity.sessionID) == [
                "first",
                "second",
                "urgent"
            ],
            "expanded rows should not move beneath the pointer"
        )
        try panelExpect(
            stabilized.health?.capabilityID == "prior",
            "expanded health controls should remain stable until collapse"
        )
    }

    private static func testExpiredExpandedAction() throws {
        let event = try panelEvent([
            "id": "expanded-expiry",
            "session_id": "session-expiry",
            "status": "done",
            "cwd": "/tmp"
        ])
        let previous = NotchPanelContent(
            events: [event],
            currentEvent: event
        )
        let expired = NotchPanelContent(
            events: [event],
            currentEvent: nil
        ).stabilized(relativeTo: previous)

        try panelExpect(
            expired.current != nil,
            "expanded legacy copy should stay visually stable"
        )
        try panelExpect(
            expired.actionableContext == nil &&
                expired.actionableIdentity == nil,
            "an expired legacy target should disable stale actions"
        )
    }

    private static func panelContent(
        rows: [SessionPresentationRow],
        health: RuntimeHealthPresentation
    ) -> NotchPanelContent {
        return NotchPanelContent(
            presentation: SessionPresentation(rows: rows, health: health),
            events: [],
            currentEvent: nil
        )
    }

    private static func panelHealth(
        id: String,
        state: RuntimeHealthState,
        recovery: String? = nil
    ) -> RuntimeHealthPresentation {
        return RuntimeHealthPresentation(
            state: state,
            capabilityID: id,
            title: "\(id) health",
            message: "\(id) message",
            recovery: recovery,
            additionalCount: 0
        )
    }

    private static func panelSessionRow(
        id: String,
        status: SessionStatus,
        evidenceAt: Date
    ) throws -> SessionPresentationRow {
        let identity = try panelRequire(
            SessionIdentity(source: "copilot", sessionID: id),
            "panel session identity should be valid"
        )
        return SessionPresentationRow(
            identity: identity,
            status: status,
            sourceLabel: "Copilot CLI",
            projectLabel: "Mews",
            sessionLabel: id,
            statusLabel: mewsStatusLabel(status.rawValue),
            statusCode: status == .needsInput ? "ASK" : "RUN",
            returnContext: nil,
            evidenceAt: evidenceAt,
            priority: status == .needsInput ? .needsInput : .running
        )
    }

    private static func panelEvent(_ overrides: [String: Any]) throws -> MewsEvent {
        var object: [String: Any] = [
            "id": UUID().uuidString,
            "source": "copilot",
            "status": "running",
            "agent_scope": "main",
            "project": "Mews",
            "message": "Working",
            "timestamp": "2026-07-21T00:00:00Z"
        ]
        for (key, value) in overrides {
            object[key] = value
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MewsEvent.self, from: data)
    }

    private static func panelExpect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw NotchPanelContentTestFailure(message: message)
        }
    }

    private static func panelRequire<T>(
        _ value: T?,
        _ message: String
    ) throws -> T {
        guard let value else {
            throw NotchPanelContentTestFailure(message: message)
        }
        return value
    }
}

private struct NotchPanelContentTestFailure: Error {
    let message: String
}
