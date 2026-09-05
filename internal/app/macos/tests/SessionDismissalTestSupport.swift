import Foundation

extension MewsAppModelTests {
    static func restorationEvents(now: Date) throws -> [MewsEvent] {
        return [
            try sessionEvent(
                id: "restore-initial",
                sessionID: "restore",
                status: "done",
                hookEvent: "agentStop",
                timestamp: now
            ),
            try sessionEvent(
                id: "restore-initial",
                sessionID: "restore",
                status: "done",
                hookEvent: "agentStop",
                timestamp: now
            ),
            try sessionEvent(
                id: "restore-older",
                sessionID: "restore",
                status: "done",
                hookEvent: "agentStop",
                timestamp: now.addingTimeInterval(-1)
            ),
            try sessionEvent(
                id: "restore-subagent",
                sessionID: "restore",
                status: "done",
                hookEvent: "agentStop",
                agentScope: "subagent",
                timestamp: now.addingTimeInterval(2)
            ),
            try sessionEvent(
                id: "restore-recoverable",
                sessionID: "restore",
                status: "failed",
                hookEvent: "agentStop",
                recoverable: true,
                timestamp: now.addingTimeInterval(3)
            ),
            try sessionEvent(
                id: "restore-newer",
                sessionID: "restore",
                status: "done",
                hookEvent: "agentStop",
                timestamp: now.addingTimeInterval(4)
            )
        ]
    }

    static func terminalSlotDismissalEvents(now: Date) throws -> [MewsEvent] {
        return try ["slot-first", "slot-second"].map { id in
            try sessionEvent(
                id: id,
                sessionID: id,
                status: "done",
                hookEvent: "agentStop",
                cwd: "/tmp/slot",
                terminal: "kitty",
                terminalWindowID: "7",
                kittyListenOn: "unix:/tmp/kitty",
                timestamp: now
            )
        }
    }

    static func dismissalRequest(for event: MewsEvent) -> SessionDismissalRequest {
        SessionDismissalRequest(
            identity: eventIdentity(event),
            evidenceID: event.id ?? ""
        )
    }

    static func eventIdentity(_ event: MewsEvent) -> SessionIdentity {
        guard let identity = SessionIdentity(source: event.source, sessionID: event.sessionID) else {
            preconditionFailure("invalid dismissal fixture identity")
        }
        return identity
    }

    static func awaitDismissal(
        _ controller: SessionStateController,
        request: SessionDismissalRequest
    ) throws -> SessionDismissalResponse {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<SessionDismissalResponse, Error>?
        controller.dismiss(request) {
            result = $0
            semaphore.signal()
        }
        semaphore.wait()
        guard let result else {
            throw SessionTestFailure(message: "dismissal did not complete")
        }
        return try result.get()
    }

    static func expectCorruptStore(_ store: SessionStateStore) throws {
        do {
            _ = try store.load()
            throw SessionTestFailure(message: "invalid dismissal metadata should be corrupt")
        } catch SessionStateStoreError.corruptData {
            return
        }
    }

    static func removeDismissalKey(from url: URL) throws {
        var object = try sessionJSON(at: url)
        var sessions = try sessionRequire(object["sessions"] as? [[String: Any]], "sessions missing")
        sessions[0].removeValue(forKey: "dismissedEvidenceID")
        object["sessions"] = sessions
        try writeSessionJSON(object, to: url)
    }

    static func addDismissalKey(_ value: String, to url: URL) throws {
        var object = try sessionJSON(at: url)
        var sessions = try sessionRequire(object["sessions"] as? [[String: Any]], "sessions missing")
        sessions[0]["dismissedEvidenceID"] = value
        object["sessions"] = sessions
        try writeSessionJSON(object, to: url)
    }

    static func removeOrderingAndAddDismissal(
        from url: URL,
        evidenceID: String
    ) throws {
        var object = try sessionJSON(at: url)
        object.removeValue(forKey: "nextEvidenceOrdinal")
        var sessions = try sessionRequire(object["sessions"] as? [[String: Any]], "sessions missing")
        sessions[0].removeValue(forKey: "evidenceOrdinal")
        sessions[0].removeValue(forKey: "equivalentEvidenceIDs")
        sessions[0].removeValue(forKey: "equivalentEvidenceOverflow")
        sessions[0]["dismissedEvidenceID"] = evidenceID
        object["sessions"] = sessions
        try writeSessionJSON(object, to: url)
    }

    static func removeOrderingMetadataUnchecked(from url: URL) {
        try? removeOrderingAndKeepVisible(from: url)
    }

    private static func removeOrderingAndKeepVisible(from url: URL) throws {
        var object = try sessionJSON(at: url)
        object.removeValue(forKey: "nextEvidenceOrdinal")
        var sessions = try sessionRequire(object["sessions"] as? [[String: Any]], "sessions missing")
        sessions[0].removeValue(forKey: "evidenceOrdinal")
        sessions[0].removeValue(forKey: "equivalentEvidenceIDs")
        sessions[0].removeValue(forKey: "equivalentEvidenceOverflow")
        object["sessions"] = sessions
        try writeSessionJSON(object, to: url)
    }

    private static func sessionJSON(at url: URL) throws -> [String: Any] {
        try sessionRequire(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
            "session snapshot should be an object"
        )
    }

    private static func writeSessionJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    static func dismissalEventLines(_ events: [MewsEvent]) throws -> Data {
        let formatter = ISO8601DateFormatter()
        return try events.map { event in
            let object: [String: Any] = [
                "id": event.id as Any,
                "source": event.source,
                "status": event.status,
                "timestamp": formatter.string(from: event.timestamp),
                "session_id": event.sessionID as Any,
                "agent_scope": event.agentScope as Any,
                "hook_event": event.hookEvent as Any
            ]
            return try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
        }.reduce(into: Data()) { result, line in
            result.append(line)
        }
    }
}
