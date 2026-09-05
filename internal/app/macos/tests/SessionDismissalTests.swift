import Foundation

extension MewsAppModelTests {
    static func testSessionDismissal() throws {
        try testDismissalDecodeAndCorruption()
        try testDismissalEligibilityAndIdempotence()
        try testDismissalWriteRollback()
        try testDismissalRestart()
        try testDismissalRestorationRules()
        try testDismissalOrderingUnavailable()
        try testDismissalWinnerFiltering()
        try testDismissalPreCASScan()
        try testDismissalReplayOverflowClearsHiddenState()
        try testDismissalNoOpDoesNotWrite()
        try testDismissalEmptyResyncDoesNotWrite()
        try testDismissalFreshnessBoundaries()
        try testDismissalControllerTransactions()
    }

    private static func testDismissalDecodeAndCorruption() throws {
        let directory = try sessionScratchDirectory("dismissal-decode")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_900_001_000)
        let event = try sessionEvent(
            id: "dismissal-decode",
            sessionID: "dismissal-decode",
            status: "done",
            hookEvent: "agentStop",
            timestamp: now
        )
        let store = SessionStateStore(url: directory.appendingPathComponent("sessions.json"))
        _ = try store.recover(from: [event], now: now)
        try removeDismissalKey(from: store.url)
        let decoded = try store.load()
        try sessionExpect(
            decoded.persistedRecords.first?.dismissedEvidenceID == nil,
            "an absent dismissal key should decode as visible"
        )

        try addDismissalKey("other", to: store.url)
        try expectCorruptStore(store)

        _ = try store.recover(
            from: try (1...65).map { number in
                try sessionEvent(
                    id: "dismissal-overflow-\(number)",
                    sessionID: "dismissal-overflow",
                    status: "done",
                    hookEvent: "agentStop",
                    timestamp: now
                )
            },
            now: now
        )
        try addDismissalKey("dismissal-overflow-65", to: store.url)
        try expectCorruptStore(store)

        _ = try store.recover(from: [event], now: now)
        try removeOrderingAndAddDismissal(from: store.url, evidenceID: event.id ?? "")
        try expectCorruptStore(store)
    }

    private static func testDismissalEligibilityAndIdempotence() throws {
        let directory = try sessionScratchDirectory("dismissal-eligibility")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_900_001_100)
        let done = try sessionEvent(
            id: "eligible-stop",
            sessionID: "eligible-stop",
            status: "done",
            hookEvent: "agentStop",
            timestamp: now
        )
        let running = try sessionEvent(
            id: "ineligible-running",
            sessionID: "ineligible-running",
            status: "running",
            hookEvent: "agentRunning",
            timestamp: now
        )
        let closed = try sessionEvent(
            id: "ineligible-closed",
            sessionID: "ineligible-closed",
            status: "idle",
            hookEvent: "sessionEnd",
            timestamp: now
        )
        let expired = try sessionEvent(
            id: "ineligible-expired",
            sessionID: "ineligible-expired",
            status: "done",
            timestamp: now.addingTimeInterval(-31 * 60)
        )
        let repository = try SessionStateRepository(
            store: SessionStateStore(url: directory.appendingPathComponent("sessions.json")),
            clock: { now }
        )
        _ = try repository.apply([done, running, closed, expired])

        try sessionExpect(
            try repository.dismiss(dismissalRequest(for: done)) == .dismissed,
            "a displayable STOP should be dismissible"
        )
        try sessionExpect(
            try repository.dismiss(dismissalRequest(for: done)) == .alreadyDismissed,
            "repeating the same dismissal should be idempotent"
        )
        for event in [running, closed, expired] {
            try sessionExpect(
                try repository.dismiss(dismissalRequest(for: event)) == .ineligibleState,
                "non-STOP states should reject dismissal"
            )
        }
    }

    private static func testDismissalWriteRollback() throws {
        let directory = try sessionScratchDirectory("dismissal-write")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_900_001_200)
        let event = try sessionEvent(
            id: "dismissal-write",
            sessionID: "dismissal-write",
            status: "done",
            hookEvent: "agentStop",
            timestamp: now
        )
        let blockingParent = directory.appendingPathComponent("blocked-parent")
        try FileManager.default.createDirectory(at: blockingParent, withIntermediateDirectories: true)
        let blockedURL = blockingParent.appendingPathComponent("sessions.json")
        let blockedRepository = try SessionStateRepository(
            store: SessionStateStore(url: blockedURL),
            clock: { now }
        )
        _ = try blockedRepository.apply([event])
        let persistedBeforeFailure = try Data(contentsOf: blockedURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: blockingParent.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: blockingParent.path
            )
        }
        do {
            _ = try blockedRepository.dismiss(dismissalRequest(for: event))
            throw SessionTestFailure(message: "a failed dismissal write should throw")
        } catch SessionStateStoreError.writeFailed {
            try sessionExpect(
                blockedRepository.currentSession(for: eventIdentity(event))?.isDismissed == false,
                "a failed dismissal write must leave memory unchanged"
            )
            try sessionExpect(
                try Data(contentsOf: blockedURL) == persistedBeforeFailure,
                "a failed dismissal write must leave the persisted snapshot unchanged"
            )
        }
    }

    private static func testDismissalRestart() throws {
        let directory = try sessionScratchDirectory("dismissal-restart")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_900_001_250)
        let event = try sessionEvent(
            id: "dismissal-restart",
            sessionID: "dismissal-restart",
            status: "done",
            hookEvent: "agentStop",
            timestamp: now
        )
        let storeURL = directory.appendingPathComponent("sessions.json")
        let repository = try SessionStateRepository(
            store: SessionStateStore(url: storeURL),
            clock: { now }
        )
        _ = try repository.apply([event])
        try sessionExpect(
            try repository.dismiss(dismissalRequest(for: event)) == .dismissed,
            "the writable repository should persist dismissal"
        )
        let restarted = try SessionStateRepository(
            store: SessionStateStore(url: storeURL),
            clock: { now }
        )
        try sessionExpect(
            restarted.currentSession(for: eventIdentity(event))?.isDismissed == true,
            "dismissal should survive restart"
        )
    }

    private static func testDismissalRestorationRules() throws {
        let now = Date(timeIntervalSince1970: 1_900_001_300)
        let events = try restorationEvents(now: now)
        let initial = events[0]
        let same = events[1]
        let older = events[2]
        let subagent = events[3]
        let recoverable = events[4]
        let newer = events[5]
        var index = SessionStateIndex.rebuilding(from: [initial], now: now)
        let identity = eventIdentity(initial)
        try sessionExpect(
            index.dismiss(
                SessionDismissalRequest(identity: identity, evidenceID: initial.id ?? ""),
                now: now
            ) == .dismissed,
            "the initial STOP should be hidden"
        )
        _ = index.apply([same, older, subagent, recoverable], now: now)
        try sessionExpect(
            index.currentSessions(now: now).first?.isDismissed == true,
            "replays, older, subagent, and recoverable evidence must not restore a row"
        )
        _ = index.apply(newer, now: newer.timestamp)
        try sessionExpect(
            index.currentSessions(now: newer.timestamp).first?.isDismissed == false &&
                index.currentSessions(now: newer.timestamp).first?.evidenceID == newer.id,
            "strictly newer primary evidence should restore the row"
        )
    }

    private static func testDismissalOrderingUnavailable() throws {
        let directory = try sessionScratchDirectory("dismissal-ordering")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_900_001_400)
        let event = try sessionEvent(
            id: "ordering-unavailable",
            sessionID: "ordering-unavailable",
            status: "done",
            hookEvent: "agentStop",
            timestamp: now
        )
        let store = SessionStateStore(url: directory.appendingPathComponent("sessions.json"))
        _ = try store.recover(from: [event], now: now)
        removeOrderingMetadataUnchecked(from: store.url)
        let repository = try SessionStateRepository(store: store, clock: { now })
        try sessionExpect(
            try repository.dismiss(dismissalRequest(for: event)) == .orderingUnavailable,
            "unknown append order should block dismissal"
        )
    }

    private static func testDismissalWinnerFiltering() throws {
        let now = Date(timeIntervalSince1970: 1_900_001_500)
        let events = try terminalSlotDismissalEvents(now: now)
        let first = events[0]
        let second = events[1]
        var index = SessionStateIndex.rebuilding(from: [first, second], now: now)
        let sessions = index.currentSessions(now: now)
        let presentation = SessionPresentationPolicy.resolve(
            sessions: sessions,
            attentionRecords: [],
            healthSnapshot: nil,
            now: now
        )
        try sessionExpect(
            presentation.rows.map(\.identity.sessionID) == ["slot-second"],
            "the highest ordered terminal-slot winner should be selected first"
        )
        let winner = try sessionRequire(
            sessions.first { $0.evidenceID == second.id },
            "the terminal-slot winner should be present"
        )
        try sessionExpect(
            index.dismiss(
                SessionDismissalRequest(
                    identity: winner.identity,
                    evidenceID: winner.evidenceID
                ),
                now: now
            ) == .dismissed,
            "the unique terminal-slot winner should be dismissible"
        )
        let hidden = SessionPresentationPolicy.resolve(
            sessions: index.currentSessions(now: now),
            attentionRecords: [],
            healthSnapshot: nil,
            now: now
        )
        try sessionExpect(
            hidden.rows.isEmpty,
            "hiding a winner must not reveal an older same-slot row"
        )
    }

    private static func testDismissalPreCASScan() throws {
        let directory = try sessionScratchDirectory("dismissal-pre-cas")
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        let now = Date(timeIntervalSince1970: 1_900_001_600)
        let first = try sessionEvent(
            id: "pre-cas-first",
            sessionID: "pre-cas",
            status: "done",
            hookEvent: "agentStop",
            timestamp: now
        )
        let second = try sessionEvent(
            id: "pre-cas-second",
            sessionID: "pre-cas",
            status: "done",
            hookEvent: "agentStop",
            timestamp: now.addingTimeInterval(1)
        )
        try dismissalEventLines([first]).write(to: eventsURL)
        let reader = EventLogReader(url: eventsURL)
        let controller = try SessionStateController(
            storeDirectory: directory,
            eventsURL: eventsURL,
            clock: { now.addingTimeInterval(2) }
        )
        _ = try reconcileSessionState(controller, reload: reader.reload())
        let handle = try FileHandle(forWritingTo: eventsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: dismissalEventLines([second]))
        try handle.close()
        let response = try awaitDismissal(
            controller,
            request: SessionDismissalRequest(
                identity: eventIdentity(first),
                evidenceID: first.id ?? ""
            )
        )
        try sessionExpect(
            response.result == .staleEvidence &&
                response.snapshot.sessions.first?.evidenceID == second.id &&
                response.snapshot.sessions.first?.isDismissed == false,
            "pre-CAS unseen evidence should win before a stale dismissal"
        )
    }

    private static func testDismissalNoOpDoesNotWrite() throws {
        let directory = try sessionScratchDirectory("dismissal-no-op")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_900_001_700)
        let event = try sessionEvent(
            id: "dismissal-no-op",
            sessionID: "dismissal-no-op",
            status: "done",
            hookEvent: "agentStop",
            timestamp: now
        )
        let repository = try SessionStateRepository(
            store: SessionStateStore(url: directory.appendingPathComponent("sessions.json")),
            clock: { now }
        )
        _ = try repository.apply([event])
        let scan = SessionEvidenceScan(
            events: [],
            candidateAnchor: nil,
            didResync: false
        )
        try sessionExpect(
            try repository.dismiss(dismissalRequest(for: event), after: scan) == .dismissed,
            "the first dismissal should persist"
        )
        try FileManager.default.removeItem(at: directory)
        try Data("blocked".utf8).write(to: directory)
        try sessionExpect(
            try repository.dismiss(dismissalRequest(for: event), after: scan) ==
                .alreadyDismissed,
            "an idempotent dismissal should not require another store write"
        )
    }

    private static func testDismissalReplayOverflowClearsHiddenState() throws {
        let now = Date(timeIntervalSince1970: 1_900_001_800)
        let events = try (1...65).map { number in
            try sessionEvent(
                id: "dismissal-replay-overflow-\(number)",
                sessionID: "dismissal-replay-overflow",
                status: "done",
                hookEvent: "agentStop",
                timestamp: now
            )
        }
        guard let last = events.last else {
            throw SessionTestFailure(message: "overflow fixtures should not be empty")
        }
        var index = SessionStateIndex.rebuilding(from: [last], now: now)
        try sessionExpect(
            index.dismiss(dismissalRequest(for: last), now: now) == .dismissed,
            "the isolated current evidence should be dismissible"
        )
        _ = index.rebuildOrdering(from: events, now: now)
        let current = try sessionRequire(
            index.currentSessions(now: now).first,
            "overflow replay should retain the current session"
        )
        try sessionExpect(
            current.equivalentEvidenceOverflow && !current.isDismissed,
            "discovering an overflow tie must fail open and clear dismissal"
        )
    }

}
