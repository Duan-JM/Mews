import Foundation

extension MewsAppModelTests {
    static func testDismissalControllerTransactions() throws {
        try testControllerDismissalSuccess()
        try testDismissalIgnoresRegressiveBoundary()
        try testDismissalCompletesStartupReconciliation()
    }

    private static func testControllerDismissalSuccess() throws {
        let directory = try sessionScratchDirectory("dismissal-controller-success")
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        let now = Date(timeIntervalSince1970: 1_900_002_000)
        let event = try sessionEvent(
            id: "controller-success",
            sessionID: "controller-success",
            status: "done",
            hookEvent: "agentStop",
            timestamp: now
        )
        try dismissalEventLines([event]).write(to: eventsURL)
        let controller = try SessionStateController(
            storeDirectory: directory,
            eventsURL: eventsURL,
            clock: { now }
        )
        let initial = try reconcileSessionState(
            controller,
            reload: EventLogReader(url: eventsURL).reload()
        )
        let response = try awaitDismissal(
            controller,
            request: dismissalRequest(for: event)
        )
        try sessionExpect(
            response.result == .dismissed &&
                response.snapshot.revision > initial.revision &&
                response.snapshot.sessions.first?.isDismissed == true &&
                response.snapshot.reconciliationAnchor != nil,
            "controller dismissal should publish a persisted hidden snapshot"
        )
        let restarted = try SessionStateRepository(
            store: SessionStateStore(url: directory.appendingPathComponent("sessions.json")),
            clock: { now }
        )
        try sessionExpect(
            restarted.currentSession(for: eventIdentity(event))?.isDismissed == true,
            "controller dismissal should survive repository restart"
        )
    }

    private static func testDismissalCompletesStartupReconciliation() throws {
        let directory = try sessionScratchDirectory("dismissal-startup")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_900_002_100)
        let initial = try sessionEvent(
            id: "startup-initial",
            sessionID: "dismissal-startup",
            status: "done",
            hookEvent: "agentStop",
            timestamp: now
        )
        let newer = try sessionEvent(
            id: "startup-newer",
            sessionID: "dismissal-startup",
            status: "running",
            hookEvent: "agentRunning",
            timestamp: now.addingTimeInterval(1)
        )
        let store = SessionStateStore(url: directory.appendingPathComponent("sessions.json"))
        _ = try store.recover(from: [initial], now: now)
        let repository = try SessionStateRepository(
            store: store,
            clock: { now.addingTimeInterval(2) }
        )
        let startupScan = SessionEvidenceScan(
            events: [initial],
            candidateAnchor: nil,
            didResync: true
        )
        try sessionExpect(
            try repository.dismiss(dismissalRequest(for: initial), after: startupScan) ==
                .dismissed,
            "startup dismissal should persist"
        )
        _ = try repository.apply(
            EventReload(
                events: [initial, newer],
                newEvents: [newer],
                recoveryEvents: []
            )
        )
        let current = try sessionRequire(
            repository.currentSession(for: eventIdentity(initial)),
            "startup session should remain available"
        )
        try sessionExpect(
            current.evidenceID == newer.id && !current.isDismissed,
            "a completed pre-CAS scan should make the next reload consume new events"
        )
    }

    private static func testDismissalIgnoresRegressiveBoundary() throws {
        let directory = try sessionScratchDirectory("dismissal-stale-boundary")
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        let now = Date(timeIntervalSince1970: 1_900_002_200)
        let (first, second) = try staleBoundaryEvents(now: now)
        try dismissalEventLines([first]).write(to: eventsURL)
        let reader = EventLogReader(url: eventsURL)
        let oldReload = try reader.reload()
        let controller = try SessionStateController(
            storeDirectory: directory,
            eventsURL: eventsURL,
            clock: { now.addingTimeInterval(1) }
        )
        _ = try reconcileSessionState(controller, reload: oldReload)
        let handle = try FileHandle(forWritingTo: eventsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: dismissalEventLines([second]))
        try handle.close()

        let stale = try awaitDismissal(
            controller,
            request: dismissalRequest(for: first)
        )
        try sessionExpect(
            stale.result == .staleEvidence &&
                stale.snapshot.sessions.first?.evidenceID == second.id,
            "pre-CAS reconciliation should publish the equal-key append winner"
        )
        let dismissed = try awaitDismissal(
            controller,
            request: dismissalRequest(for: second)
        )
        let advancedAnchor = try sessionRequire(
            dismissed.snapshot.reconciliationAnchor,
            "dismissal should retain the advanced reconciliation anchor"
        )
        let replayed = try reconcileSessionState(controller, reload: oldReload)
        try sessionExpect(
            replayed.sessions.first?.evidenceID == second.id &&
                replayed.sessions.first?.isDismissed == true &&
                replayed.reconciliationAnchor == advancedAnchor,
            "an older boundary must not regress ordering or resurrect a hidden row"
        )
    }

    private static func staleBoundaryEvents(now: Date) throws -> (MewsEvent, MewsEvent) {
        let first = try sessionEvent(
            id: "stale-boundary-first",
            sessionID: "stale-boundary",
            status: "done",
            hookEvent: "agentStop",
            timestamp: now
        )
        let second = try sessionEvent(
            id: "stale-boundary-second",
            sessionID: "stale-boundary",
            status: "done",
            hookEvent: "agentStop",
            timestamp: now
        )
        return (first, second)
    }

    static func testDismissalEmptyResyncDoesNotWrite() throws {
        let directory = try sessionScratchDirectory("dismissal-empty-resync")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_900_002_300)
        let event = try sessionEvent(
            id: "dismissal-empty-resync",
            sessionID: "dismissal-empty-resync",
            status: "done",
            hookEvent: "agentStop",
            timestamp: now
        )
        let store = SessionStateStore(url: directory.appendingPathComponent("sessions.json"))
        _ = try store.recover(from: [event], now: now)
        removeOrderingMetadataUnchecked(from: store.url)
        let repository = try SessionStateRepository(store: store, clock: { now })
        try FileManager.default.removeItem(at: directory)
        try Data("blocked".utf8).write(to: directory)
        let result = try repository.dismiss(
            dismissalRequest(for: event),
            after: SessionEvidenceScan(
                events: [],
                candidateAnchor: nil,
                didResync: true
            )
        )
        try sessionExpect(
            result == .orderingUnavailable,
            "an unchanged empty resync should not turn ordering failure into a write error"
        )
    }
}
