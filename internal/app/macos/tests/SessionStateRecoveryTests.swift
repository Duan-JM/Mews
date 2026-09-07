import Foundation

extension MewsAppModelTests {
    static func testSessionStateRecoveryFoundation() throws {
        try testControllerRetriesEvidenceAfterSaveFailure()
        try testFullReplayPreservesProvenWinner()
        try testSameSizeRewriteForcesResync()
        try testExhaustedOrdinalIsRejected()
        try testSnapshotSurvivesEventReadFailure()
        try testSessionStateReviewRegressions()
        try testSessionReplayOrdering()
    }

    private static func testControllerRetriesEvidenceAfterSaveFailure() throws {
        let directory = try sessionScratchDirectory("controller-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        let timestamp = Date(timeIntervalSince1970: 1_900_000_450)
        let first = try sessionEvent(
            id: "retry-a",
            sessionID: "retry",
            status: "running",
            timestamp: timestamp
        )
        let second = try sessionEvent(
            id: "retry-b",
            sessionID: "retry",
            status: "done",
            timestamp: timestamp.addingTimeInterval(1)
        )
        try recoveryEventLines([first]).write(to: eventsURL)
        let reader = EventLogReader(url: eventsURL)
        let controller = try SessionStateController(
            storeDirectory: directory,
            eventsURL: eventsURL,
            clock: { timestamp.addingTimeInterval(2) }
        )
        _ = try reconcileSessionState(controller, reload: reader.reload())

        let handle = try FileHandle(forWritingTo: eventsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: recoveryEventLines([second]))
        try handle.close()
        let appended = try reader.reload()
        let storeURL = directory.appendingPathComponent("sessions.json")
        try FileManager.default.removeItem(at: storeURL)
        try FileManager.default.createDirectory(
            at: storeURL,
            withIntermediateDirectories: false
        )
        let failed = reconcileSessionStateOutcome(controller, reload: appended)
        guard case SessionStateStoreError.writeFailed = try failure(from: failed) else {
            throw SessionRecoveryTestFailure(message: "session save should fail")
        }
        try sessionExpect(
            try sessionStateSnapshot(controller).sessions.first?.evidenceID == "retry-a",
            "the controller snapshot should retain the last successfully persisted evidence"
        )

        try FileManager.default.removeItem(at: storeURL)
        let recovered = try reconcileSessionState(controller, reload: reader.reload())
        try sessionExpect(
            recovered.sessions.first?.evidenceID == "retry-b",
            "the controller should retry bytes that were not persisted"
        )
    }

    private static func testFullReplayPreservesProvenWinner() throws {
        let timestamp = Date(timeIntervalSince1970: 1_900_000_500)
        let earlier = try sessionEvent(
            id: "replay-a",
            sessionID: "replay",
            status: "done",
            timestamp: timestamp
        )
        let winner = try sessionEvent(
            id: "replay-b",
            sessionID: "replay",
            status: "failed",
            timestamp: timestamp
        )
        try assertKnownReplayWinner(
            earlier: earlier,
            winner: winner,
            timestamp: timestamp
        )
        try assertUnknownReplayWinner(
            earlier: earlier,
            winner: winner,
            timestamp: timestamp
        )
    }

    private static func assertKnownReplayWinner(
        earlier: MewsEvent,
        winner: MewsEvent,
        timestamp: Date
    ) throws {
        let knownDirectory = try sessionScratchDirectory("known-replay")
        defer { try? FileManager.default.removeItem(at: knownDirectory) }
        let knownStore = SessionStateStore(
            url: knownDirectory.appendingPathComponent("sessions.json")
        )
        let knownRepository = try SessionStateRepository(
            store: knownStore,
            clock: { timestamp }
        )
        _ = try knownRepository.apply([winner])
        let persistedOrdinal = knownRepository.currentSessions().first?.evidenceOrdinal
        let knownEventsURL = knownDirectory.appendingPathComponent("events.jsonl")
        try recoveryEventLines([earlier, winner]).write(to: knownEventsURL)
        let knownController = try SessionStateController(
            storeDirectory: knownDirectory,
            eventsURL: knownEventsURL,
            clock: { timestamp }
        )
        let knownSnapshot = try reconcileSessionState(
            knownController,
            reload: EventLogReader(url: knownEventsURL).reload()
        )
        try sessionExpect(
            knownSnapshot.sessions.first?.evidenceID == "replay-b" &&
                knownSnapshot.sessions.first?.evidenceOrdinal == persistedOrdinal,
            "full replay should retain the winner and its established ordinal"
        )
    }

    private static func assertUnknownReplayWinner(
        earlier: MewsEvent,
        winner: MewsEvent,
        timestamp: Date
    ) throws {
        let unknownDirectory = try sessionScratchDirectory("unknown-replay")
        defer { try? FileManager.default.removeItem(at: unknownDirectory) }
        let unknownStore = SessionStateStore(
            url: unknownDirectory.appendingPathComponent("sessions.json")
        )
        _ = try SessionStateRepository(
            store: unknownStore,
            clock: { timestamp }
        ).apply([winner])
        try removeRecoveryOrderingMetadata(from: unknownStore.url)
        let unknownEventsURL = unknownDirectory.appendingPathComponent("events.jsonl")
        try recoveryEventLines([earlier]).write(to: unknownEventsURL)
        let unknownController = try SessionStateController(
            storeDirectory: unknownDirectory,
            eventsURL: unknownEventsURL,
            clock: { timestamp }
        )
        let unknownSnapshot = try reconcileSessionState(
            unknownController,
            reload: EventLogReader(url: unknownEventsURL).reload()
        )
        try sessionExpect(
            unknownSnapshot.sessions.first?.evidenceID == "replay-b" &&
                unknownSnapshot.sessions.first?.orderingKnown == false,
            "an unproven equal-key replay should keep persisted evidence fail-open"
        )
    }
}

private extension MewsAppModelTests {
    private static func testSameSizeRewriteForcesResync() throws {
        let directory = try sessionScratchDirectory("same-size-rewrite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        let timestamp = Date(timeIntervalSince1970: 1_900_000_550)
        let original = try sessionEvent(
            id: "same-a",
            sessionID: "same",
            status: "done",
            timestamp: timestamp
        )
        let replacement = try sessionEvent(
            id: "same-b",
            sessionID: "same",
            status: "idle",
            timestamp: timestamp
        )
        let tail = try sessionEvent(
            id: "same-tail",
            sessionID: "tail",
            status: "running",
            timestamp: timestamp.addingTimeInterval(1)
        )
        let initialData = try recoveryEventLines([original, tail])
        let replacementData = try recoveryEventLines([replacement, tail])
        try sessionExpect(
            initialData.count == replacementData.count,
            "same-size rewrite fixture should preserve the file length"
        )
        try initialData.write(to: eventsURL)
        let reader = EventLogReader(url: eventsURL)
        _ = try reader.reload()

        let handle = try FileHandle(forWritingTo: eventsURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: replacementData)
        try handle.synchronize()
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: timestamp.addingTimeInterval(30)],
            ofItemAtPath: eventsURL.path
        )
        let reload = try reader.reload()
        try sessionExpect(
            reload.sessionDidResync &&
                reload.sessionResyncEvents.map(\.id) == ["same-b", "same-tail"],
            "a same-size same-inode rewrite should force a full resync"
        )
    }

    private static func testExhaustedOrdinalIsRejected() throws {
        let timestamp = Date(timeIntervalSince1970: 1_900_000_600)
        let event = try sessionEvent(
            id: "ordinal",
            sessionID: "ordinal",
            status: "running",
            timestamp: timestamp
        )
        var index = SessionStateIndex()
        _ = index.apply(event, now: timestamp)
        do {
            _ = try SessionStateIndex(
                restoring: index.persistedRecords,
                nextEvidenceOrdinal: UInt64.max,
                orderingNeedsRebuild: false
            )
            throw SessionRecoveryTestFailure(
                message: "an exhausted ordinal should be rejected"
            )
        } catch SessionStateValidationError.invalidOrdering {
            return
        }
    }

    private static func testSnapshotSurvivesEventReadFailure() throws {
        let directory = try sessionScratchDirectory("snapshot-read-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = Date(timeIntervalSince1970: 1_900_000_650)
        let event = try sessionEvent(
            id: "persisted-after-read-failure",
            sessionID: "read-failure",
            status: "needs_input",
            timestamp: timestamp
        )
        let store = SessionStateStore(
            url: directory.appendingPathComponent("sessions.json")
        )
        _ = try SessionStateRepository(
            store: store,
            clock: { timestamp }
        ).apply([event])
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        try Data("{malformed}\n".utf8).write(to: eventsURL)
        do {
            _ = try EventLogReader(url: eventsURL).reload()
            throw SessionRecoveryTestFailure(message: "malformed event log should fail")
        } catch EventLogReadError.malformedLine {
            let controller = try SessionStateController(
                storeDirectory: directory,
                eventsURL: eventsURL,
                clock: { timestamp }
            )
            let snapshot = try sessionStateSnapshot(controller)
            try sessionExpect(
                snapshot.sessions.first?.evidenceID == event.id,
                "persisted sessions should remain available after an event read failure"
            )
        }
    }

    private static func reconcileSessionStateOutcome(
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
            SessionRecoveryTestFailure(message: "session reconciliation did not complete"),
            SessionControllerSnapshot(
                revision: 0,
                sessions: [],
                reconciliationAnchor: nil,
                orderingKnown: false
            )
        )
    }

    private static func failure(
        from outcome: SessionControllerReconciliation
    ) throws -> Error {
        switch outcome {
        case .success:
            throw SessionRecoveryTestFailure(message: "expected reconciliation to fail")
        case let .failure(error, _):
            return error
        }
    }

    private static func sessionStateSnapshot(
        _ controller: SessionStateController
    ) throws -> SessionControllerSnapshot {
        let semaphore = DispatchSemaphore(value: 0)
        var result: SessionControllerSnapshot?
        controller.snapshot {
            result = $0
            semaphore.signal()
        }
        semaphore.wait()
        return try sessionRequire(
            result,
            "session snapshot did not complete"
        )
    }

    private static func removeRecoveryOrderingMetadata(from url: URL) throws {
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

    private static func recoveryEventLines(_ events: [MewsEvent]) throws -> Data {
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

private struct SessionRecoveryTestFailure: Error {
    let message: String
}
