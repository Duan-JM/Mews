import Foundation

extension MewsAppModelTests {
    static func testReplacementWithReusedEventID() throws {
        let directory = try sessionScratchDirectory("replacement-reused-id")
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        let timestamp = Date(timeIntervalSince1970: 1_900_000_520)
        let retained = try sessionEvent(
            id: "shared-anchor",
            sessionID: "anchor-session",
            status: "running",
            timestamp: timestamp
        )
        let stopped = try sessionEvent(
            id: "middle-stop",
            sessionID: "stopped-session",
            status: "done",
            timestamp: timestamp.addingTimeInterval(1)
        )
        let reused = try sessionEvent(
            id: "shared-anchor",
            sessionID: "anchor-session",
            status: "running",
            timestamp: timestamp.addingTimeInterval(2)
        )
        try replacementEventLines([retained]).write(to: eventsURL)
        let reader = EventLogReader(url: eventsURL)
        _ = try reader.reload()
        try replacementEventLines([retained, stopped, reused]).write(
            to: eventsURL,
            options: .atomic
        )

        let reload = try reader.reload()
        try sessionExpect(
            reload.sessionDidResync &&
                reload.newEvents.compactMap(\.id) == [
                    "middle-stop", "shared-anchor"
                ],
            "replacement discovery should preserve events after the exact anchor"
        )
    }
}

private func replacementEventLines(
    _ events: [MewsEvent]
) throws -> Data {
    let formatter = ISO8601DateFormatter()
    return try events.map { event in
        var object: [String: Any] = [
            "id": event.id as Any,
            "source": event.source,
            "status": event.status,
            "timestamp": formatter.string(from: event.timestamp)
        ]
        object["session_id"] = event.sessionID
        object["agent_scope"] = event.agentScope
        object["hook_event"] = event.hookEvent
        return try JSONSerialization.data(withJSONObject: object) +
            Data([0x0A])
    }.reduce(into: Data()) { result, line in
        result.append(line)
    }
}
