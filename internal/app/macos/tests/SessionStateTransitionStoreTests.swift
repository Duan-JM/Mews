import Foundation

extension MewsAppModelTests {
    static func testResyncPreservesNewStopTransitions() throws {
        try assertResyncPreservesNewStopTransition()
        try assertResyncDropsRewrittenDuplicateStop()
        try assertResyncPreservesReusedIDStopTransition()
    }

    private static func assertResyncPreservesNewStopTransition() throws {
        let directory = try sessionScratchDirectory("resync-stop-transition")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_280)
        let events = try resyncStopEvents(now: now)
        let repository = try SessionStateRepository(
            store: SessionStateStore(
                url: directory.appendingPathComponent("sessions.json")
            ),
            clock: { now.addingTimeInterval(2) }
        )
        _ = try repository.apply(EventReload(
            events: [events.running],
            newEvents: [],
            recoveryEvents: [events.running]
        ))
        let result = try repository.applyWithResult(EventReload(
            events: [events.running, events.stopped],
            newEvents: [events.stopped],
            sessionResyncEvents: [events.running, events.stopped],
            sessionDidResync: true
        ))
        let identity = try sessionRequire(
            SessionIdentity(source: "copilot", sessionID: "resync-session"),
            "resync fixture identity should be valid"
        )
        let transition = try sessionRequire(
            result.stopTransitions.first,
            "resync should preserve one stop transition"
        )

        try sessionExpect(
            transition.candidate == SessionAttentionCandidate(
                session: try sessionRequire(
                    repository.currentSession(for: identity),
                    "resynced session should be current"
                ),
                event: events.stopped
            ),
            "a resync should preserve a newly accepted stop transition"
        )
        try sessionExpect(
            result.stopTransitionIdentifier?
                .hasSuffix("|resync-stopped") == true,
            "the resync transition should preserve event identity"
        )
    }

    private static func assertResyncDropsRewrittenDuplicateStop() throws {
        let directory = try sessionScratchDirectory("resync-duplicate-stop")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_290)
        let running = try sessionEvent(
            id: "old-running",
            sessionID: "rewritten-session",
            status: "running",
            timestamp: now
        )
        let earlierStop = try sessionEvent(
            id: "rewritten-stop",
            sessionID: "rewritten-session",
            status: "done",
            timestamp: now.addingTimeInterval(1)
        )
        let repeatedStop = try sessionEvent(
            id: "suffix-stop",
            sessionID: "rewritten-session",
            status: "done",
            timestamp: now.addingTimeInterval(2)
        )
        let repository = try SessionStateRepository(
            store: SessionStateStore(
                url: directory.appendingPathComponent("sessions.json")
            ),
            clock: { now.addingTimeInterval(3) }
        )
        _ = try repository.apply(EventReload(
            events: [running],
            newEvents: [],
            recoveryEvents: [running]
        ))
        let result = try repository.applyWithResult(EventReload(
            events: [earlierStop, repeatedStop],
            newEvents: [repeatedStop],
            sessionResyncEvents: [earlierStop, repeatedStop],
            sessionDidResync: true
        ))
        try sessionExpect(
            result.stopTransitions.isEmpty,
            "rewritten history should not redeliver an existing stopped round"
        )
    }

    private static func assertResyncPreservesReusedIDStopTransition() throws {
        let directory = try sessionScratchDirectory("resync-reused-stop-id")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_300)
        let persistedStop = try sessionEvent(
            id: "shared-stop",
            sessionID: "reused-stop-session",
            status: "done",
            timestamp: now
        )
        let running = try sessionEvent(
            id: "new-running",
            sessionID: "reused-stop-session",
            status: "running",
            timestamp: now.addingTimeInterval(1)
        )
        let newStop = try sessionEvent(
            id: "shared-stop",
            sessionID: "reused-stop-session",
            status: "done",
            timestamp: now.addingTimeInterval(2)
        )
        let repository = try SessionStateRepository(
            store: SessionStateStore(
                url: directory.appendingPathComponent("sessions.json")
            ),
            clock: { now.addingTimeInterval(3) }
        )
        _ = try repository.apply(EventReload(
            events: [persistedStop],
            newEvents: [],
            recoveryEvents: [persistedStop]
        ))
        let result = try repository.applyWithResult(EventReload(
            events: [persistedStop, running, newStop],
            newEvents: [running, newStop],
            sessionResyncEvents: [persistedStop, running, newStop],
            sessionDidResync: true
        ))
        try sessionExpect(
            result.stopTransitions.first?.candidate.key.statusChangedAt ==
                newStop.timestamp,
            "a reused event ID must not hide a new stopped round"
        )
    }

    private static func resyncStopEvents(
        now: Date
    ) throws -> (running: MewsEvent, stopped: MewsEvent) {
        return (
            try sessionEvent(
                id: "resync-running",
                sessionID: "resync-session",
                status: "running",
                timestamp: now
            ),
            try sessionEvent(
                id: "resync-stopped",
                sessionID: "resync-session",
                status: "done",
                timestamp: now.addingTimeInterval(1)
            )
        )
    }
}
