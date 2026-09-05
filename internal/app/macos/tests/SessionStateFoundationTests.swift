import Foundation

extension MewsAppModelTests {
    static func testSessionStateFoundation() throws {
        try testAppendStableTieOrdering()
        try testTieOverflowFreeze()
        try testLegacyOrderingRebuild()
        try testEventReaderRotationAndAnchorMismatch()
        try testEvidenceReaderCursor()
        try testSessionStateRecoveryFoundation()
        try testSessionSaveFailureIsCopyOnWrite()
        try testSessionConsumersDoNotWriteTheSessionStore()
    }

    private static func testAppendStableTieOrdering() throws {
        let timestamp = Date(timeIntervalSince1970: 1_900_000_000)
        let first = try sessionEvent(
            id: "tie-a",
            sessionID: "tie",
            status: "done",
            timestamp: timestamp
        )
        let second = try sessionEvent(
            id: "tie-b",
            sessionID: "tie",
            status: "done",
            timestamp: timestamp
        )
        var index = SessionStateIndex()
        _ = index.apply([first, second], now: timestamp)
        let current = try sessionRequire(
            index.currentSessions(now: timestamp).first,
            "tie evidence should create a current session"
        )
        try sessionExpect(current.evidenceID == "tie-b", "append order should win a tie")
        try sessionExpect(
            current.evidenceOrdinal == 2 &&
                current.orderingKnown,
            "accepted evidence should have a global ordinal"
        )
        try sessionExpect(
            !index.apply(first, now: timestamp),
            "replaying a tie ID should not change the winner"
        )
    }

    private static func testTieOverflowFreeze() throws {
        let timestamp = Date(timeIntervalSince1970: 1_900_000_100)
        let events = try (1...66).map { number in
            try sessionEvent(
                id: "overflow-\(number)",
                sessionID: "overflow",
                status: "done",
                timestamp: timestamp
            )
        }
        var index = SessionStateIndex()
        _ = index.apply(events, now: timestamp)
        let frozen = try sessionRequire(
            index.currentSessions(now: timestamp).first,
            "overflow evidence should remain readable"
        )
        try sessionExpect(
            frozen.evidenceID == "overflow-65" &&
                frozen.orderingKnown,
            "the bounded tie set should freeze at its capacity"
        )
        try sessionExpect(
            !index.apply(events[0], now: timestamp) &&
                !index.apply(events[65], now: timestamp),
            "evicted and later tie IDs should remain replay-safe"
        )
        let newer = try sessionEvent(
            id: "overflow-new",
            sessionID: "overflow",
            status: "done",
            timestamp: timestamp.addingTimeInterval(1)
        )
        try sessionExpect(
            index.apply(newer, now: newer.timestamp),
            "strictly newer evidence should thaw a frozen tie"
        )
    }

    private static func testLegacyOrderingRebuild() throws {
        let directory = try sessionScratchDirectory("legacy-ordering")
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = Date(timeIntervalSince1970: 1_900_000_200)
        let fixture = try legacyOrderingEvents(at: timestamp)
        let store = SessionStateStore(url: directory.appendingPathComponent("sessions.json"))
        let repository = try SessionStateRepository(store: store, clock: { timestamp })
        _ = try repository.apply([fixture.first, fixture.second, fixture.retained])
        try removeOrderingMetadata(from: store.url)

        let eventsURL = directory.appendingPathComponent("events.jsonl")
        try eventLines([fixture.first, fixture.second]).write(to: eventsURL)
        let controller = try SessionStateController(
            storeDirectory: directory,
            eventsURL: eventsURL,
            clock: { timestamp }
        )
        let reload = try EventLogReader(url: eventsURL).reload()
        let snapshot = try reconcileSessionState(controller, reload: reload)
        let rebuiltSession = try sessionRequire(
            snapshot.sessions.first { $0.sessionID == "legacy" },
            "legacy ordering should rebuild the matched session"
        )
        try sessionExpect(
            rebuiltSession.evidenceID == "legacy-b" && rebuiltSession.orderingKnown,
            "rebuild should retain the append-ordered winner"
        )
        let retainedSession = try sessionRequire(
            snapshot.sessions.first { $0.sessionID == "legacy-retained" },
            "persisted evidence missing from the log should remain available"
        )
        try sessionExpect(
            retainedSession.evidenceID == "legacy-retained" &&
                !retainedSession.orderingKnown &&
                retainedSession.project == "PersistedProject" &&
                retainedSession.returnContext?.workingDirectory == "/tmp/persisted",
            "rebuild must not downgrade or erase metadata for unproven persisted evidence"
        )
    }

    private static func legacyOrderingEvents(
        at timestamp: Date
    ) throws -> LegacyOrderingFixture {
        let first = try sessionEvent(
            id: "legacy-a",
            sessionID: "legacy",
            status: "done",
            timestamp: timestamp
        )
        let second = try sessionEvent(
            id: "legacy-b",
            sessionID: "legacy",
            status: "done",
            timestamp: timestamp
        )
        let retained = try sessionEvent(
            id: "legacy-retained",
            sessionID: "legacy-retained",
            status: "needs_input",
            project: "PersistedProject",
            cwd: "/tmp/persisted",
            timestamp: timestamp.addingTimeInterval(10)
        )
        return LegacyOrderingFixture(first: first, second: second, retained: retained)
    }

    private struct LegacyOrderingFixture {
        let first: MewsEvent
        let second: MewsEvent
        let retained: MewsEvent
    }
}

extension MewsAppModelTests {
    private static func testEventReaderRotationAndAnchorMismatch() throws {
        let directory = try sessionScratchDirectory("event-reader")
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        let timestamp = Date(timeIntervalSince1970: 1_900_000_300)
        let first = try sessionEvent(
            id: "reader-a",
            sessionID: "reader",
            status: "running",
            timestamp: timestamp
        )
        let second = try sessionEvent(
            id: "reader-b",
            sessionID: "reader",
            status: "done",
            timestamp: timestamp.addingTimeInterval(1)
        )
        try eventLines([first]).write(to: eventsURL)
        let reader = EventLogReader(url: eventsURL)
        _ = try reader.reload()
        try appendEvent(second, to: eventsURL)
        let appended = try reader.reload()
        try sessionExpect(
            appended.newEvents.map(\.id) == ["reader-b"],
            "append reload should expose only the new complete line"
        )
        try assertReaderReplacement(
            reader,
            eventsURL: eventsURL,
            first: first,
            timestamp: timestamp
        )
        try assertReaderRotationAndEmpty(
            reader,
            directory: directory,
            eventsURL: eventsURL,
            timestamp: timestamp
        )
    }

    private static func appendEvent(_ event: MewsEvent, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: eventLines([event]))
        try handle.close()
    }

    private static func assertReaderReplacement(
        _ reader: EventLogReader,
        eventsURL: URL,
        first: MewsEvent,
        timestamp: Date
    ) throws {
        let replacement = try sessionEvent(
            id: "reader-replacement",
            sessionID: "reader",
            status: "failed",
            timestamp: timestamp.addingTimeInterval(2)
        )
        let rewrite = try FileHandle(forWritingTo: eventsURL)
        try rewrite.truncate(atOffset: 0)
        try rewrite.write(contentsOf: eventLines([first, replacement]))
        try rewrite.close()
        let resync = try reader.reload()
        try sessionExpect(
            resync.sessionResyncEvents.map(\.id) == ["reader-a", "reader-replacement"],
            "same-inode rewrite should publish a complete resync batch"
        )
        try sessionExpect(
            resync.newEvents.isEmpty,
            "a missing notification anchor should not redeliver replacement history"
        )
    }

    private static func assertReaderRotationAndEmpty(
        _ reader: EventLogReader,
        directory: URL,
        eventsURL: URL,
        timestamp: Date
    ) throws {
        let rotated = directory.appendingPathComponent("events.rotated")
        try FileManager.default.moveItem(at: eventsURL, to: rotated)
        let rotatedEvent = try sessionEvent(
            id: "reader-rotated",
            sessionID: "reader",
            status: "running",
            timestamp: timestamp.addingTimeInterval(3)
        )
        try eventLines([rotatedEvent]).write(to: eventsURL)
        let rotatedReload = try reader.reload()
        try sessionExpect(
            rotatedReload.sessionResyncEvents.map(\.id) == ["reader-rotated"],
            "path rotation should resync the replacement inode"
        )
        try sessionExpect(
            rotatedReload.newEvents.isEmpty,
            "rotation without the prior anchor should remain notification-silent"
        )

        let emptyRewrite = try FileHandle(forWritingTo: eventsURL)
        try emptyRewrite.truncate(atOffset: 0)
        try emptyRewrite.close()
        let emptyReload = try reader.reload()
        try sessionExpect(
            emptyReload.sessionDidResync &&
                emptyReload.sessionResyncEvents.isEmpty &&
                emptyReload.sessionCandidateAnchor?.offset == 0,
            "an empty replacement should still publish a stable resync anchor"
        )
    }

    private static func testEvidenceReaderCursor() throws {
        let directory = try sessionScratchDirectory("evidence-reader")
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        let timestamp = Date(timeIntervalSince1970: 1_900_000_400)
        let first = try sessionEvent(
            id: "scan-a",
            sessionID: "scan",
            status: "running",
            timestamp: timestamp
        )
        let second = try sessionEvent(
            id: "scan-b",
            sessionID: "scan",
            status: "done",
            timestamp: timestamp.addingTimeInterval(1)
        )
        try eventLines([first]).write(to: eventsURL)
        let reader = SessionEvidenceReader(url: eventsURL)
        let initial = try reader.scan(anchor: nil)
        let handle = try FileHandle(forWritingTo: eventsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: eventLines([second]))
        try handle.close()
        let tail = try reader.scan(anchor: initial.candidateAnchor)
        try sessionExpect(
            tail.events.map(\.id) == ["scan-b"],
            "ordered evidence scans should read only the unseen tail"
        )
    }

    private static func testSessionSaveFailureIsCopyOnWrite() throws {
        let directory = try sessionScratchDirectory("save-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: parent)
        let store = SessionStateStore(
            url: parent.appendingPathComponent("sessions.json")
        )
        let repository = try SessionStateRepository(store: store)
        let event = try sessionEvent(
            id: "save-failure",
            sessionID: "save-failure",
            status: "running",
            timestamp: Date().addingTimeInterval(-1)
        )
        do {
            _ = try repository.apply([event])
            throw SessionTestFailure(message: "a blocked store write should fail")
        } catch SessionStateStoreError.writeFailed {
            try sessionExpect(
                repository.sessionCount == 0,
                "a failed save must not advance repository memory"
            )
        }
    }

    private static func testSessionConsumersDoNotWriteTheSessionStore() throws {
        let directory = try sessionScratchDirectory("sole-owner")
        defer { try? FileManager.default.removeItem(at: directory) }
        let event = try sessionEvent(
            id: "sole-owner",
            sessionID: "sole-owner",
            status: "done",
            timestamp: Date().addingTimeInterval(-1)
        )
        let reload = EventReload(
            events: [event],
            newEvents: [event],
            recoveryEvents: [event]
        )
        _ = SessionPresentationSource().sessions(reconciling: reload)
        var index = SessionStateIndex()
        _ = index.apply([event], now: event.timestamp)
        _ = try AttentionController(storeDirectory: directory).reconcile(
            reload,
            sessions: index.currentSessions(now: event.timestamp)
        )
        try sessionExpect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("sessions.json").path
            ),
            "read-only consumers must not create the session store"
        )
    }

    static func reconcileSessionState(
        _ controller: SessionStateController,
        reload: EventReload
    ) throws -> SessionControllerSnapshot {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<SessionControllerSnapshot, Error>?
        var callbackWasOnMainThread = true
        controller.reconcile(reload) {
            callbackWasOnMainThread = Thread.isMainThread
            outcome = $0
            semaphore.signal()
        }
        semaphore.wait()
        try sessionExpect(
            !callbackWasOnMainThread,
            "session reconciliation should complete off the main thread"
        )
        return try sessionRequire(
            outcome,
            "session reconciliation did not complete"
        ).get()
    }

    private static func removeOrderingMetadata(from url: URL) throws {
        let data = try Data(contentsOf: url)
        var object = try sessionRequire(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "legacy fixture should be an object"
        )
        object.removeValue(forKey: "nextEvidenceOrdinal")
        var sessions = try sessionRequire(
            object["sessions"] as? [[String: Any]],
            "legacy fixture should contain sessions"
        )
        for index in sessions.indices {
            sessions[index].removeValue(forKey: "evidenceOrdinal")
            sessions[index].removeValue(forKey: "equivalentEvidenceIDs")
            sessions[index].removeValue(forKey: "equivalentEvidenceOverflow")
        }
        object["sessions"] = sessions
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private static func eventLines(_ events: [MewsEvent]) throws -> Data {
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
            let line = try JSONSerialization.data(withJSONObject: object)
            return line + Data([0x0A])
        }.reduce(into: Data()) { result, line in
            result.append(line)
        }
    }
}
