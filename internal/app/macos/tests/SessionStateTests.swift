import Foundation

extension MewsAppModelTests {
    static func testRecoverableSessionState() throws {
        try testIndependentSessions()
        try testSourceParticipatesInIdentity()
        try testInPlaceSessionUpdates()
        try testMetadataRetentionAndReplacement()
        try testOutOfOrderAndDuplicateEvidence()
        try testEqualTimeEvidencePrecedence()
        try testSessionContextValidation()
        try testRecoverableSessionStateStore()
        try testSessionPresentation()
        try testSessionPresentationSource()
    }

    private static func testIndependentSessions() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var index = SessionStateIndex()
        let events = try parallelSessionEvents(start: start) + secondarySessionEvidence(start: start)

        try sessionExpect(
            index.apply(events, now: start.addingTimeInterval(5)),
            "primary session evidence should update the index"
        )
        try sessionExpect(index.count == 2, "missing IDs and secondary evidence should stay history-only")

        let sessions = index.currentSessions(now: start.addingTimeInterval(5))
        let first = try sessionRequire(
            sessions.first { $0.identity == SessionIdentity(source: "copilot", sessionID: "session-a") },
            "the first session should remain independently addressable"
        )
        let second = try sessionRequire(
            sessions.first { $0.identity == SessionIdentity(source: "copilot", sessionID: "session-b") },
            "the second session should remain independently addressable"
        )
        try sessionExpect(first.status == .running, "subagent and recoverable events should not replace main state")
        try sessionExpect(first.project == "Mews", "session project should follow accepted evidence")
        try sessionExpect(second.status == .needsInput, "parallel sessions should retain independent statuses")
        try sessionExpect(second.hookEvent == "PermissionRequest", "session hook should follow accepted evidence")
        try sessionExpect(
            first.returnContext?.returnCommand != second.returnContext?.returnCommand,
            "parallel sessions should retain distinct return contexts"
        )
        try sessionExpect(
            second.returnContext?.kittyTarget?.windowID == "22",
            "terminal context should stay per session"
        )
    }

    private static func testSourceParticipatesInIdentity() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_050)
        var index = SessionStateIndex()
        let first = try sessionEvent(
            id: "copilot-shared",
            source: "copilot",
            sessionID: "shared-id",
            status: "running",
            timestamp: timestamp
        )
        let second = try sessionEvent(
            id: "claude-shared",
            source: "claude-code",
            sessionID: "shared-id",
            status: "done",
            timestamp: timestamp
        )

        _ = index.apply([first, second], now: timestamp)
        try sessionExpect(index.count == 2, "source and session ID together should define stable identity")
    }

    private static func testInPlaceSessionUpdates() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_100)
        let sessionID = "same-session"
        var index = SessionStateIndex()
        let running = try sessionEvent(
            id: "running-1",
            sessionID: sessionID,
            status: "running",
            project: "Before",
            timestamp: start
        )
        let runningEvidence = try sessionEvent(
            id: "running-2",
            sessionID: sessionID,
            status: "running",
            project: "After",
            hookEvent: "sessionStart",
            timestamp: start.addingTimeInterval(10)
        )
        let done = try sessionEvent(
            id: "done",
            sessionID: sessionID,
            status: "done",
            hookEvent: "agentStop",
            timestamp: start.addingTimeInterval(20)
        )

        try sessionExpect(index.apply(running, now: running.timestamp), "the first event should create the session")
        try sessionExpect(
            index.apply(runningEvidence, now: runningEvidence.timestamp),
            "newer evidence should update the session in place"
        )
        let current = try sessionRequire(
            index.currentSessions(now: start.addingTimeInterval(11)).first,
            "updated session should be readable"
        )
        try sessionExpect(index.count == 1, "updates should not duplicate the stable session identity")
        try sessionExpect(current.statusChangedAt == start, "same-status evidence should preserve change time")
        try sessionExpect(
            current.evidenceAt == start.addingTimeInterval(10),
            "same-status evidence should advance evidence time"
        )
        try sessionExpect(current.project == "After", "newer metadata should replace prior metadata")

        try applyDoneAndAssert(done, to: &index, start: start)
    }

    private static func applyDoneAndAssert(
        _ done: MewsEvent,
        to index: inout SessionStateIndex,
        start: Date
    ) throws {
        try sessionExpect(index.apply(done, now: done.timestamp), "a newer status should replace the current status")
        let current = try sessionRequire(
            index.currentSessions(now: start.addingTimeInterval(21)).first,
            "completed session should remain readable"
        )
        try sessionExpect(current.status == .done, "newer terminal evidence should update status")
        try sessionExpect(
            current.statusChangedAt == start.addingTimeInterval(20),
            "a status transition should update change time"
        )
    }

    private static func testOutOfOrderAndDuplicateEvidence() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_200)
        var index = SessionStateIndex()
        let done = try sessionEvent(
            id: "done-new",
            sessionID: "ordered",
            status: "done",
            hookEvent: "agentStop",
            timestamp: timestamp
        )
        let olderRunning = try sessionEvent(
            id: "running-old",
            sessionID: "ordered",
            status: "running",
            timestamp: timestamp.addingTimeInterval(-1)
        )

        try sessionExpect(index.apply(done, now: timestamp), "terminal evidence should initialize the session")
        try sessionExpect(
            !index.apply(olderRunning, now: timestamp),
            "older evidence should not roll status backward"
        )
        try sessionExpect(!index.apply(done, now: timestamp), "duplicate evidence should not rewrite the session")
        try testLegacyEvidenceOrdering(timestamp: timestamp)
    }

    private static func testLegacyEvidenceOrdering(timestamp: Date) throws {
        let older = try sessionEvent(
            id: nil,
            sessionID: "legacy",
            status: "running",
            project: "Mews",
            timestamp: timestamp
        )
        let newer = try sessionEvent(
            id: nil,
            sessionID: "legacy",
            status: "running",
            project: "Mews",
            timestamp: timestamp.addingTimeInterval(1)
        )
        var index = SessionStateIndex()

        try sessionExpect(index.apply(older, now: newer.timestamp), "legacy evidence should initialize the session")
        try sessionExpect(
            index.apply(newer, now: newer.timestamp),
            "newer legacy evidence should advance evidence time"
        )
        try sessionExpect(
            !index.apply(newer, now: newer.timestamp),
            "an exact legacy replay should remain ignored"
        )
        try sessionExpect(
            index.currentSessions(now: timestamp.addingTimeInterval(2)).first?.evidenceAt == newer.timestamp,
            "the latest legacy timestamp should be retained"
        )
    }

    private static func testEqualTimeEvidencePrecedence() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_200)
        var equalTime = SessionStateIndex()
        let running = try sessionEvent(
            id: "z-running",
            sessionID: "equal-time",
            status: "running",
            timestamp: timestamp
        )
        let sessionEnd = try sessionEvent(
            id: "a-session-end",
            sessionID: "equal-time",
            status: "idle",
            hookEvent: "sessionEnd",
            timestamp: timestamp
        )
        _ = equalTime.apply([running, sessionEnd], now: timestamp)
        try sessionExpect(
            equalTime.currentSessions(now: timestamp).first?.evidenceStatus == .idle,
            "explicit session end should win equal-time evidence"
        )

        var reverseOrder = SessionStateIndex()
        _ = reverseOrder.apply([sessionEnd, running], now: timestamp)
        try sessionExpect(
            reverseOrder.currentSessions(now: timestamp).first?.evidenceStatus == .idle,
            "equal-time precedence should be independent of arrival order"
        )

        var processExitOrder = SessionStateIndex()
        let runnerDone = try sessionEvent(
            id: "a-runner-done",
            source: "runner",
            sessionID: "command",
            status: "done",
            timestamp: timestamp
        )
        let runnerRunning = try sessionEvent(
            id: "z-runner-running",
            source: "runner",
            sessionID: "command",
            status: "running",
            timestamp: timestamp
        )
        _ = processExitOrder.apply([runnerDone, runnerRunning], now: timestamp)
        try sessionExpect(
            processExitOrder.currentSessions(now: timestamp).first?.evidenceStatus == .done,
            "process-exit evidence should win equal-time runner updates"
        )
    }

    private static func testSessionContextValidation() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_350)
        let unsafe = try sessionEvent(
            id: "unsafe-context",
            sessionID: "unsafe-context",
            status: "running",
            terminal: "kitty",
            terminalWindowID: "window-17",
            kittyListenOn: "tcp:127.0.0.1:5000",
            timestamp: timestamp
        )
        var index = SessionStateIndex()
        _ = index.apply(
            unsafe,
            now: timestamp,
            cliExecutablePath: "/opt/mews/bin/mw"
        )
        let context = try sessionRequire(
            index.currentSessions(now: timestamp).first?.returnContext,
            "the generated history command should keep return context available"
        )
        try sessionExpect(context.returnCommand != nil, "session identity should produce a local return command")
        try sessionExpect(context.kittyTarget == nil, "unsafe terminal metadata should remain filtered")
    }
}

extension MewsAppModelTests {
    static func parallelSessionEvents(start: Date) throws -> [MewsEvent] {
        return [
            try sessionEvent(
                id: "a-running",
                source: "copilot",
                sessionID: "session-a",
                status: "running",
                project: "Mews",
                hookEvent: "sessionStart",
                timestamp: start
            ),
            try sessionEvent(
                id: "b-input",
                source: "copilot",
                sessionID: "session-b",
                status: "needs_input",
                project: "Mews",
                hookEvent: "PermissionRequest",
                terminal: "kitty",
                terminalWindowID: "22",
                kittyListenOn: "unix:/Users/example/second-kitty.sock",
                timestamp: start.addingTimeInterval(1)
            )
        ]
    }

    static func secondarySessionEvidence(start: Date) throws -> [MewsEvent] {
        return [
            try sessionEvent(
                id: "missing-id",
                sessionID: nil,
                status: "done",
                timestamp: start.addingTimeInterval(2)
            ),
            try sessionEvent(
                id: "a-subagent",
                sessionID: "session-a",
                status: "done",
                agentScope: "subagent",
                timestamp: start.addingTimeInterval(3)
            ),
            try sessionEvent(
                id: "a-recoverable",
                sessionID: "session-a",
                status: "failed",
                recoverable: true,
                timestamp: start.addingTimeInterval(4)
            )
        ]
    }

    static func sessionEvent(
        id: String?,
        source: String = "copilot",
        sessionID: String?,
        status: String,
        project: String? = nil,
        hookEvent: String? = nil,
        agentScope: String = "main",
        recoverable: Bool? = nil,
        cwd: String? = nil,
        terminal: String? = nil,
        terminalWindowID: String? = nil,
        kittyListenOn: String? = nil,
        timestamp: Date
    ) throws -> MewsEvent {
        var object: [String: Any] = [
            "source": source,
            "status": status,
            "agent_scope": agentScope,
            "timestamp": ISO8601DateFormatter().string(from: timestamp)
        ]
        object["id"] = id
        object["session_id"] = sessionID
        object["project"] = project
        object["hook_event"] = hookEvent
        object["recoverable"] = recoverable
        object["cwd"] = cwd
        object["terminal"] = terminal
        object["terminal_window_id"] = terminalWindowID
        object["kitty_listen_on"] = kittyListenOn
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MewsEvent.self, from: data)
    }

    static func sessionScratchDirectory(_ name: String) throws -> URL {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist", isDirectory: true)
            .appendingPathComponent("session-state-tests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

func sessionRequire<Value>(_ value: Value?, _ message: String) throws -> Value {
    guard let value else {
        throw SessionTestFailure(message: message)
    }
    return value
}

func sessionExpect(_ condition: Bool, _ message: String) throws {
    guard condition else {
        throw SessionTestFailure(message: message)
    }
}

struct SessionTestFailure: Error {
    let message: String
}
