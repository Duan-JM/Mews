import Foundation

extension MewsAppModelTests {
    static func testSessionStateReviewRegressions() throws {
        try testControllerStopsAtForegroundBoundary()
        try testShorterBoundaryRetriesAfterSaveFailure()
        try testOverflowWinnerSurvivesCompactedReplay()
        try testFullReplayReplacesFutureRecord()
        try testFullReplayPreservesNewStatusRound()
        try testFullReplayIgnoresEarlierStatusChanges()
        try testGrowingRewriteForcesResync()
        try testReplacementWithReusedEventID()
    }

    private static func testControllerStopsAtForegroundBoundary() throws {
        let directory = try sessionScratchDirectory("controller-boundary")
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        let timestamp = Date(timeIntervalSince1970: 1_900_000_475)
        let running = try sessionEvent(
            id: "boundary-running",
            sessionID: "boundary",
            status: "running",
            timestamp: timestamp
        )
        let done = try sessionEvent(
            id: "boundary-done",
            sessionID: "boundary",
            status: "done",
            timestamp: timestamp.addingTimeInterval(1)
        )
        try regressionEventLines([running]).write(to: eventsURL)
        let reader = EventLogReader(url: eventsURL)
        let controller = try SessionStateController(
            storeDirectory: directory,
            eventsURL: eventsURL,
            clock: { timestamp.addingTimeInterval(2) }
        )
        let foregroundReload = try reader.reload()
        try appendRegressionEvent(done, to: eventsURL)

        let bounded = try reconcileSessionState(controller, reload: foregroundReload)
        try sessionExpect(
            bounded.sessions.first?.evidenceID == "boundary-running",
            "the controller must not scan beyond the foreground reload boundary"
        )
        let caughtUp = try reconcileSessionState(controller, reload: reader.reload())
        try sessionExpect(
            caughtUp.sessions.first?.evidenceID == "boundary-done",
            "the next foreground reload should publish later evidence"
        )
    }

    private static func testShorterBoundaryRetriesAfterSaveFailure() throws {
        let directory = try sessionScratchDirectory("short-boundary-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        let timestamp = Date(timeIntervalSince1970: 1_900_000_485)
        let fixture = try shorterBoundaryFixture(at: timestamp)
        let initialData = try regressionEventLines(fixture.initial)
        let replacementData = try regressionEventLines([fixture.replacement])
        try sessionExpect(
            replacementData.count < initialData.count,
            "the replacement boundary should be shorter than the committed anchor"
        )
        try initialData.write(to: eventsURL)
        let reader = EventLogReader(url: eventsURL)
        let controller = try SessionStateController(
            storeDirectory: directory,
            eventsURL: eventsURL,
            clock: { timestamp.addingTimeInterval(3) }
        )
        _ = try reconcileSessionState(controller, reload: reader.reload())
        try replaceRegressionLog(at: eventsURL, with: replacementData)
        let replacementReload = try reader.reload()

        let storeURL = directory.appendingPathComponent("sessions.json")
        try FileManager.default.removeItem(at: storeURL)
        try FileManager.default.createDirectory(
            at: storeURL,
            withIntermediateDirectories: false
        )
        let failed = regressionReconciliationOutcome(
            controller,
            reload: replacementReload
        )
        guard case let .failure(_, snapshot) = failed else {
            throw SessionStateRegressionFailure(message: "short resync save should fail")
        }
        try sessionExpect(
            snapshot.sessions.first?.evidenceID == fixture.initial.last?.id,
            "a failed resync should return its transaction-local persisted snapshot"
        )
        guard case SessionStateStoreError.writeFailed = try regressionFailure(failed) else {
            throw SessionStateRegressionFailure(message: "short resync save should fail")
        }

        try FileManager.default.removeItem(at: storeURL)
        let recovered = try reconcileSessionState(controller, reload: reader.reload())
        try sessionExpect(
            recovered.sessions.first?.evidenceID == fixture.replacement.id,
            "a shorter resync should retry after its first save failure"
        )
    }

    private static func testOverflowWinnerSurvivesCompactedReplay() throws {
        let timestamp = Date(timeIntervalSince1970: 1_900_000_525)
        let initial = try (1...65).map { number in
            try sessionEvent(
                id: "overflow-\(number)",
                sessionID: "overflow-replay",
                status: "done",
                timestamp: timestamp
            )
        }
        let compacted = try (3...66).map { number in
            try sessionEvent(
                id: "overflow-\(number)",
                sessionID: "overflow-replay",
                status: "done",
                timestamp: timestamp
            )
        }
        var index = SessionStateIndex()
        _ = index.apply(initial, now: timestamp)
        _ = index.rebuildOrdering(from: compacted, now: timestamp)
        let record = try sessionRequire(
            index.persistedRecords.first,
            "overflow replay should retain a record"
        )
        try sessionExpect(
            record.evidenceID == "overflow-65" &&
                record.equivalentEvidenceOverflow,
            "a compacted replay must not replace an overflow-frozen winner"
        )
    }

    private static func testFullReplayReplacesFutureRecord() throws {
        let directory = try sessionScratchDirectory("future-resync")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_900_000_535)
        let futureTime = now.addingTimeInterval(
            SessionFreshnessPolicy.standard.futureTolerance + 60
        )
        let future = try sessionEvent(
            id: "future-resync",
            sessionID: "future-resync",
            status: "running",
            timestamp: futureTime
        )
        let store = SessionStateStore(
            url: directory.appendingPathComponent("sessions.json")
        )
        try store.save(SessionStateIndex.rebuilding(from: [future], now: futureTime))
        let repository = try SessionStateRepository(
            store: store,
            clock: { now }
        )
        let current = try sessionEvent(
            id: "current-resync",
            sessionID: "future-resync",
            status: "needs_input",
            timestamp: now
        )
        _ = try repository.rebuildOrdering(from: [current])
        try sessionExpect(
            repository.currentSessions().first?.evidenceID == "current-resync",
            "a full replay should replace persisted evidence beyond the future tolerance"
        )
    }

    private static func testFullReplayPreservesNewStatusRound() throws {
        let timestamp = Date(timeIntervalSince1970: 1_900_000_545)
        let firstDone = try sessionEvent(
            id: "round-done-1",
            sessionID: "round-replay",
            status: "done",
            timestamp: timestamp
        )
        let running = try sessionEvent(
            id: "round-running",
            sessionID: "round-replay",
            status: "running",
            timestamp: timestamp.addingTimeInterval(1)
        )
        let secondDone = try sessionEvent(
            id: "round-done-2",
            sessionID: "round-replay",
            status: "done",
            timestamp: timestamp.addingTimeInterval(2)
        )
        var index = SessionStateIndex.rebuilding(from: [firstDone], now: timestamp)
        let prior = try sessionRequire(
            index.currentSessions(now: timestamp).first,
            "the initial attention round should exist"
        )
        let delivered = AttentionReconciler().reconcile(
            candidates: [try regressionAttentionCandidate(prior)],
            state: AttentionState()
        )

        _ = index.rebuildOrdering(
            from: [firstDone, running, secondDone],
            now: secondDone.timestamp
        )
        let current = try sessionRequire(
            index.currentSessions(now: secondDone.timestamp).first,
            "the replayed attention round should exist"
        )
        let repeated = AttentionReconciler().reconcile(
            candidates: [try regressionAttentionCandidate(current)],
            state: delivered.state
        )
        try sessionExpect(
            current.statusChangedAt == secondDone.timestamp &&
                repeated.newlyAlertable.count == 1,
            "an intervening status must establish a new attention round"
        )
    }

    private static func testFullReplayIgnoresEarlierStatusChanges() throws {
        let timestamp = Date(timeIntervalSince1970: 1_900_000_555)
        let earlierRunning = try sessionEvent(
            id: "earlier-running",
            sessionID: "same-round-replay",
            status: "running",
            timestamp: timestamp
        )
        let persistedDone = try sessionEvent(
            id: "persisted-done",
            sessionID: "same-round-replay",
            status: "done",
            timestamp: timestamp.addingTimeInterval(1)
        )
        let laterDone = try sessionEvent(
            id: "later-done",
            sessionID: "same-round-replay",
            status: "done",
            timestamp: timestamp.addingTimeInterval(2)
        )
        var index = SessionStateIndex.rebuilding(
            from: [persistedDone],
            now: laterDone.timestamp
        )
        _ = index.rebuildOrdering(
            from: [earlierRunning, laterDone],
            now: laterDone.timestamp
        )
        let current = try sessionRequire(
            index.currentSessions(now: laterDone.timestamp).first,
            "the same-status replay should retain a session"
        )
        try sessionExpect(
            current.statusChangedAt == persistedDone.timestamp,
            "an earlier replayed status must not create a later attention round"
        )
    }

    private static func testGrowingRewriteForcesResync() throws {
        let directory = try sessionScratchDirectory("growing-rewrite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        let timestamp = Date(timeIntervalSince1970: 1_900_000_575)
        let original = try sessionEvent(
            id: "grow-a",
            sessionID: "grow",
            status: "running",
            timestamp: timestamp
        )
        let replacement = try sessionEvent(
            id: "grow-b",
            sessionID: "grow",
            status: "running",
            timestamp: timestamp
        )
        let tail = try sessionEvent(
            id: "grow-tail",
            sessionID: "tail",
            status: "running",
            timestamp: timestamp.addingTimeInterval(1)
        )
        let appended = try sessionEvent(
            id: "grow-new",
            sessionID: "new",
            status: "done",
            timestamp: timestamp.addingTimeInterval(2)
        )
        try regressionEventLines([original, tail]).write(to: eventsURL)
        let reader = EventLogReader(url: eventsURL)
        _ = try reader.reload()
        let replacementData = try regressionEventLines([replacement, tail, appended])

        let handle = try FileHandle(forWritingTo: eventsURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: replacementData)
        try handle.truncate(atOffset: UInt64(replacementData.count))
        try handle.close()
        let reload = try reader.reload()
        try sessionExpect(
            reload.sessionDidResync &&
                reload.sessionResyncEvents.map(\.id) == [
                    "grow-b", "grow-tail", "grow-new"
                ] &&
                reload.newEvents.map(\.id) == ["grow-new"],
            "a growing same-inode rewrite should resync without redelivering old events"
        )
    }

    private static func appendRegressionEvent(
        _ event: MewsEvent,
        to url: URL
    ) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: regressionEventLines([event]))
        try handle.close()
    }

    private static func replaceRegressionLog(
        at url: URL,
        with data: Data
    ) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private static func shorterBoundaryFixture(
        at timestamp: Date
    ) throws -> (initial: [MewsEvent], replacement: MewsEvent) {
        let first = try sessionEvent(
            id: "long-boundary-running",
            sessionID: "short-boundary",
            status: "running",
            timestamp: timestamp
        )
        let second = try sessionEvent(
            id: "long-boundary-done",
            sessionID: "short-boundary",
            status: "done",
            timestamp: timestamp.addingTimeInterval(1)
        )
        let replacement = try sessionEvent(
            id: "short-failed",
            sessionID: "short-boundary",
            status: "failed",
            timestamp: timestamp.addingTimeInterval(2)
        )
        return ([first, second], replacement)
    }

    private static func regressionEventLines(_ events: [MewsEvent]) throws -> Data {
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

    private static func regressionAttentionCandidate(
        _ session: CurrentSessionState
    ) throws -> SessionAttentionCandidate {
        return try sessionRequire(
            SessionAttentionCandidate(session: session),
            "the completion should be alertable"
        )
    }

    private static func regressionReconciliationOutcome(
        _ controller: SessionStateController,
        reload: EventReload
    ) -> SessionControllerReconciliation {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: SessionControllerReconciliation?
        controller.reconcile(reload) {
            outcome = $0
            semaphore.signal()
        }
        semaphore.wait()
        return outcome ?? .failure(
            SessionStateRegressionFailure(message: "reconciliation did not complete"),
            SessionControllerSnapshot(
                revision: 0,
                sessions: [],
                reconciliationAnchor: nil,
                orderingKnown: false
            )
        )
    }

    private static func regressionFailure(
        _ outcome: SessionControllerReconciliation
    ) throws -> Error {
        switch outcome {
        case .success:
            throw SessionStateRegressionFailure(message: "expected reconciliation failure")
        case let .failure(error, _):
            return error
        }
    }
}

private struct SessionStateRegressionFailure: Error {
    let message: String
}
