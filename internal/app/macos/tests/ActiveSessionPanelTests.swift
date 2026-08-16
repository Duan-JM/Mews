import Foundation

extension MewsAppModelTests {
    static func testActiveSessionPanel() throws {
        try testKnownLifecyclePresence()
        try testCodexLifecyclePresence()
        try testUnknownPresenceExpiry()
        try testActivePresenceFiltering()
        try testSubagentRunningPresentation()
        try testResolvedStoppedPriority()
        try testScrollableActiveSessionPanel()
        try testExpandedActiveSessionStability()
        try testSupersededTerminalSessionFiltering()
    }

    private static func testCodexLifecyclePresence() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_160)
        var index = SessionStateIndex()
        let running = try sessionEvent(
            id: "codex-running",
            source: "codex",
            sessionID: "codex-lifecycle",
            status: "running",
            hookEvent: "UserPromptSubmit",
            timestamp: start
        )
        _ = index.apply(running, now: start)
        let open = try sessionRequire(
            index.currentSessions(now: start).first,
            "Codex running lifecycle evidence should be indexed"
        )
        try sessionExpect(
            open.presence == .open && open.presentationStatus == .running,
            "Codex UserPromptSubmit should present an open running session"
        )

        let ended = try sessionEvent(
            id: "codex-ended",
            source: "codex",
            sessionID: "codex-lifecycle",
            status: "idle",
            hookEvent: "SessionEnd",
            timestamp: start.addingTimeInterval(1)
        )
        _ = index.apply(ended, now: ended.timestamp)
        let closed = try sessionRequire(
            index.currentSessions(now: ended.timestamp).first,
            "Codex SessionEnd evidence should remain indexed"
        )
        try sessionExpect(
            closed.presence == .closed,
            "Codex SessionEnd should remove the session from active presentation"
        )
    }

    private static func testSubagentRunningPresentation() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_360)
        let session = try activeSession(
            id: "subagent-running",
            status: .running,
            evidenceAt: now,
            hookEvent: "subagentRunning"
        )
        let presentation = SessionPresentationPolicy.resolve(
            sessions: [session],
            attentionRecords: [],
            healthSnapshot: nil,
            now: now
        )
        let row = try sessionRequire(
            presentation.rows.first,
            "subagent-running session should be displayed"
        )
        try sessionExpect(
            row.statusLabel == "Subagent Running" && row.statusCode == "SUB",
            "deferred Copilot completion should identify active subagents"
        )
        try sessionExpect(
            row.priority == .running,
            "subagent-running sessions should retain running priority"
        )
    }

    private static func testKnownLifecyclePresence() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_150)
        var index = SessionStateIndex()
        let ended = try sessionEvent(
            id: "ended",
            sessionID: "lifecycle",
            status: "idle",
            hookEvent: "sessionEnd",
            timestamp: start
        )
        _ = index.apply(ended, now: ended.timestamp)
        let closed = try sessionRequire(
            index.currentSessions(now: ended.timestamp).first,
            "the ended session should remain available as closure evidence"
        )
        try sessionExpect(closed.presence == .closed, "sessionEnd should close a session")

        let resumed = try sessionEvent(
            id: "resumed",
            sessionID: "lifecycle",
            status: "running",
            hookEvent: "userPromptSubmitted",
            timestamp: start.addingTimeInterval(1)
        )
        _ = index.apply(resumed, now: resumed.timestamp)
        let open = try sessionRequire(
            index.currentSessions(now: resumed.timestamp).first,
            "newer lifecycle evidence should reopen the session"
        )
        try sessionExpect(open.presence == .open, "newer primary evidence should reopen a session")
    }

    private static func testUnknownPresenceExpiry() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_175)
        var index = SessionStateIndex()
        let event = try sessionEvent(
            id: "codex-done",
            source: "codex",
            sessionID: "codex-session",
            status: "done",
            hookEvent: "agent-turn-complete",
            timestamp: timestamp
        )
        _ = index.apply(event, now: timestamp)
        let current = try sessionRequire(
            index.currentSessions(
                now: timestamp.addingTimeInterval(31 * 60)
            ).first,
            "unknown-presence evidence should remain stored"
        )
        try sessionExpect(
            current.presence == .unknown &&
                current.status == .idle &&
                !current.isFresh,
            "Codex completion should expire without claiming the session stayed open"
        )
    }

    private static func testActivePresenceFiltering() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_350)
        let presentation = try activePresencePresentation(now: now)

        try sessionExpect(
            Set(presentation.rows.map(\.identity.sessionID)) ==
                Set(["stopped-open", "claude-started"]),
            "only known-open sessions should outlive settled freshness"
        )
        try sessionExpect(
            presentation.rows.allSatisfy {
                $0.statusLabel == "Stopped" && $0.statusCode == "STOP"
            },
            "open sessions between turns should render as stopped"
        )
        try sessionExpect(
            presentation.rows.allSatisfy { $0.priority == .recent },
            "presence-only stopped rows should not look like unacknowledged completions"
        )
    }

    private static func activePresencePresentation(
        now: Date
    ) throws -> SessionPresentation {
        let sessions = try [
            activeSession(
                id: "stopped-open",
                status: .idle,
                evidenceStatus: .done,
                evidenceAt: now.addingTimeInterval(-(31 * 60)),
                hookEvent: "agentStop",
                isFresh: false
            ),
            activeSession(
                id: "claude-started",
                source: "claude-code",
                status: .idle,
                evidenceAt: now,
                hookEvent: "SessionStart"
            ),
            activeSession(
                id: "closed",
                status: .idle,
                evidenceAt: now,
                hookEvent: "sessionEnd"
            ),
            activeSession(
                id: "codex-expired",
                source: "codex",
                status: .idle,
                evidenceStatus: .done,
                evidenceAt: now.addingTimeInterval(-(31 * 60)),
                hookEvent: "agent-turn-complete",
                isFresh: false
            )
        ]
        return SessionPresentationPolicy.resolve(
            sessions: sessions,
            attentionRecords: [],
            healthSnapshot: nil,
            now: now
        )
    }

    private static func testResolvedStoppedPriority() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_360)
        let session = try activeSession(
            id: "resolved",
            status: .done,
            evidenceAt: now
        )
        let key = try sessionRequire(
            AttentionKey(
                identity: session.identity,
                status: .done,
                statusChangedAt: now
            ),
            "resolved completion key should be valid"
        )
        let presentation = SessionPresentationPolicy.resolve(
            sessions: [session],
            attentionRecords: [
                AttentionRecord(
                    identity: session.identity,
                    key: key,
                    disposition: .resolved
                )
            ],
            healthSnapshot: nil,
            now: now
        )

        try sessionExpect(
            presentation.rows.first?.priority == .recent,
            "resolved completions should remain stopped without renewed attention"
        )
    }

    private static func testScrollableActiveSessionPanel() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_375)
        let sessions = try (0..<6).map { index in
            try activeSession(
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
        let content = NotchPanelContent(
            presentation: presentation,
            events: [],
            currentEvent: nil
        )

        try sessionExpect(
            content.visibleSessionRows.count == 6 &&
                presentation.menuRows.count == 5,
            "the panel should retain every active row while the menu stays bounded"
        )
    }

    private static func testExpandedActiveSessionStability() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_390)
        let previous = try ["first", "second"].map {
            try activeSession(id: $0, status: .running, evidenceAt: now)
        }
        let canonical = try [
            activeSession(
                id: "urgent",
                status: .needsInput,
                evidenceAt: now.addingTimeInterval(1)
            ),
            activeSession(id: "first", status: .running, evidenceAt: now)
        ]
        let oldRows = SessionPresentationPolicy.resolve(
            sessions: previous,
            attentionRecords: [],
            healthSnapshot: nil,
            now: now
        ).rows
        let newRows = SessionPresentationPolicy.resolve(
            sessions: canonical,
            attentionRecords: [],
            healthSnapshot: nil,
            now: now
        ).rows
        let stabilized = SessionPresentationPolicy.stabilizedRows(
            canonical: newRows,
            previous: oldRows
        )

        try sessionExpect(
            stabilized.map(\.identity.sessionID) == ["first", "urgent"],
            "closed sessions should disappear without moving retained rows"
        )
    }

    private static func testSupersededTerminalSessionFiltering() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_400)
        let presentation = SessionPresentationPolicy.resolve(
            sessions: try terminalSlotSessions(now: now),
            attentionRecords: [],
            healthSnapshot: nil,
            now: now
        )

        try sessionExpect(
            Set(presentation.rows.map(\.identity.sessionID)) == Set([
                "tmux-current",
                "tmux-parallel",
                "kitty-current",
                "kitty-parallel"
            ]),
            "a newer session should replace only the older row from the same terminal slot"
        )
    }

    private static func terminalSlotSessions(
        now: Date
    ) throws -> [CurrentSessionState] {
        return try [
            terminalSession("tmux-stale", .idle, .done, now.addingTimeInterval(-28_800), "2", "%0"),
            terminalSession("tmux-current", .running, nil, now, "1", "%0"),
            terminalSession("tmux-parallel", .running, nil, now.addingTimeInterval(-1), "3", "%1"),
            terminalSession("kitty-stale", .idle, .done, now.addingTimeInterval(-3_600), "4"),
            terminalSession("kitty-current", .running, nil, now.addingTimeInterval(-2), "4"),
            terminalSession("kitty-parallel", .running, nil, now.addingTimeInterval(-3), "5"),
            terminalSession("tmux-before-close", .idle, .done, now.addingTimeInterval(-7_200), "6", "%2"),
            terminalSession("tmux-closed", .idle, nil, now.addingTimeInterval(-4), "7", "%2")
        ]
    }

    private static func terminalSession(
        _ id: String,
        _ status: SessionStatus,
        _ evidenceStatus: SessionStatus?,
        _ evidenceAt: Date,
        _ windowID: String,
        _ tmuxPane: String? = nil
    ) throws -> CurrentSessionState {
        let identity = try sessionRequire(
            SessionIdentity(source: "copilot", sessionID: id),
            "terminal session identity should be valid"
        )
        let resolvedEvidenceStatus = evidenceStatus ?? status
        return CurrentSessionState(
            identity: identity,
            status: status,
            evidenceStatus: resolvedEvidenceStatus,
            statusChangedAt: evidenceAt,
            evidenceAt: evidenceAt,
            project: "Mews",
            hookEvent: status == .running
                ? "userPromptSubmitted"
                : (resolvedEvidenceStatus == .idle ? "sessionEnd" : "agentStop"),
            returnContext: CLIContextPayload(
                returnCommand: "mw history --session '\(id)'",
                workingDirectory: "/tmp",
                terminal: "kitty",
                terminalWindowID: windowID,
                kittyListenOn: "unix:/tmp/kitty-control",
                tmuxSocket: tmuxPane == nil ? nil : "/private/tmp/tmux-501/default",
                tmuxPane: tmuxPane,
                tmuxClient: tmuxPane == nil ? nil : "/dev/ttys\(windowID)"
            ),
            isFresh: status != .idle
        )
    }

    private static func activeSession(
        id: String,
        source: String = "copilot",
        status: SessionStatus,
        evidenceStatus: SessionStatus? = nil,
        evidenceAt: Date,
        hookEvent: String? = "testLifecycle",
        isFresh: Bool = true
    ) throws -> CurrentSessionState {
        let identity = try sessionRequire(
            SessionIdentity(source: source, sessionID: id),
            "active session identity should be valid"
        )
        return CurrentSessionState(
            identity: identity,
            status: status,
            evidenceStatus: evidenceStatus ?? status,
            statusChangedAt: evidenceAt,
            evidenceAt: evidenceAt,
            project: "Mews",
            hookEvent: hookEvent,
            returnContext: CLIContextPayload(
                returnCommand: "mw history --session '\(id)'",
                workingDirectory: "/tmp"
            ),
            isFresh: isFresh
        )
    }
}
