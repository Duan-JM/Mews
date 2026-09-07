import Foundation

extension MewsAppModelTests {
    static func testSessionPresentationSource() throws {
        try testAttentionIndependentSessionSource()
        try testSessionSourceBurstRecovery()
        try testSessionSourceResyncOrdering()
    }

    private static func testAttentionIndependentSessionSource() throws {
        let directory = try sessionPresentationSourceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"version":1,"records":"invalid"}"#.utf8).write(
            to: directory.appendingPathComponent("attention.json")
        )
        var attentionFailed = false
        do {
            _ = try AttentionController(storeDirectory: directory)
        } catch {
            attentionFailed = true
        }
        let now = Date(timeIntervalSince1970: 1_900_000_700)
        let event = sessionPresentationSourceEvent(at: now)
        let sessions = SessionPresentationSource(
            clock: { now }
        ).sessions(
            reconciling: EventReload(
                events: [event],
                newEvents: [event],
                recoveryEvents: [event]
            )
        )

        try sessionPresentationSourceExpect(
            attentionFailed,
            "the fixture should reproduce unavailable attention state"
        )
        try sessionPresentationSourceExpect(
            sessions.map(\.sessionID) == ["attention-independent"],
            "session navigation should remain available when attention state is corrupt"
        )
    }

    private static func testSessionSourceBurstRecovery() throws {
        let directory = try sessionPresentationSourceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_900_000_700)
        let initial = sessionPresentationSourceEvent(at: now)
        let source = SessionPresentationSource(
            clock: { now }
        )
        _ = source.sessions(
            reconciling: EventReload(
                events: [initial],
                newEvents: [initial],
                recoveryEvents: [initial]
            )
        )
        let burst = (0..<12).map { index in
            sessionPresentationSourceEvent(
                at: now.addingTimeInterval(TimeInterval(index + 1)),
                sessionID: "burst-\(index)"
            )
        }
        let recovered = source.sessions(
            reconciling: EventReload(
                events: Array(burst.suffix(10)),
                newEvents: burst
            )
        )
        try sessionPresentationSourceExpect(
            recovered.count == 13 &&
                recovered.contains { $0.sessionID == "burst-0" },
            "fallback recovery should include a burst larger than visible history"
        )
    }

    private static func testSessionSourceResyncOrdering() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_800)
        let earlier = try sessionEvent(
            id: "fallback-a",
            sessionID: "fallback-order",
            status: "done",
            timestamp: now
        )
        let winner = try sessionEvent(
            id: "fallback-b",
            sessionID: "fallback-order",
            status: "failed",
            timestamp: now
        )
        let source = SessionPresentationSource(clock: { now })
        _ = source.sessions(
            reconciling: EventReload(
                events: [winner],
                newEvents: [],
                recoveryEvents: [winner]
            )
        )
        let sessions = source.sessions(
            reconciling: EventReload(
                events: [earlier, winner],
                newEvents: [],
                sessionResyncEvents: [earlier, winner],
                sessionDidResync: true
            )
        )
        try sessionPresentationSourceExpect(
            sessions.first?.evidenceID == "fallback-b",
            "fallback resync should preserve the append-ordered winner"
        )
    }

    private static func sessionPresentationSourceDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mews-presentation-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func sessionPresentationSourceEvent(
        at timestamp: Date,
        sessionID: String = "attention-independent"
    ) -> MewsEvent {
        return MewsEvent(
            id: "presentation-source-\(sessionID)",
            source: "copilot",
            status: "needs_input",
            hookEvent: nil,
            launchContext: nil,
            agentScope: "main",
            recoverable: nil,
            sessionID: sessionID,
            project: "Mews",
            taskTitle: nil,
            message: "Needs input",
            cwd: "/tmp",
            terminal: nil,
            terminalWindowID: nil,
            kittyListenOn: nil,
            tmuxSocket: nil,
            tmuxPane: nil,
            tmuxClient: nil,
            timestamp: timestamp
        )
    }

    private static func sessionPresentationSourceExpect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw SessionPresentationSourceTestFailure(message: message)
        }
    }
}

private struct SessionPresentationSourceTestFailure: Error {
    let message: String
}
