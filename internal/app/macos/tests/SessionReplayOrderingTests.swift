import Foundation

extension MewsAppModelTests {
    static func testSessionReplayOrdering() throws {
        try testReplayOrderingReservesOrdinalCapacity()
        try testPartialReplayRestoresSharedSlotOrder()
        try testReplayOrderingCoverage()
        try testReplayOrderingPreservesDismissal()
        try testReplayOrderingIsolatesOtherTimestamps()
        try testIncompleteReplayRejectsConflictingOrder()
    }

    private static func testPartialReplayRestoresSharedSlotOrder() throws {
        let directory = try sessionScratchDirectory("partial-replay-ordering")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_900_000_700)
        let events = try terminalSlotDismissalEvents(now: now)
        let initial = SessionStateIndex.rebuilding(from: events, now: now)
        try expectReplayWinners(initial.currentSessions(now: now), ["slot-second"], now: now)
        let legacy = try SessionStateIndex(
            restoring: initial.persistedRecords.map { $0.withUnknownOrdering() }
        )
        let store = SessionStateStore(url: directory.appendingPathComponent("sessions.json"))
        try store.save(legacy)
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        try dismissalEventLines([events[1]]).write(to: eventsURL, options: .atomic)
        let reader = EventLogReader(url: eventsURL)
        let controller = try SessionStateController(
            storeDirectory: directory,
            eventsURL: eventsURL,
            clock: { now }
        )
        let partial = try reconcileSessionState(controller, reload: reader.reload())
        try sessionExpect(
            !partial.orderingKnown &&
                partial.sessions.first { $0.sessionID == "slot-second" }?.evidenceOrdinal == 1,
            "the partial replay should learn B while A remains unknown"
        )

        try dismissalEventLines(events).write(to: eventsURL, options: .atomic)
        let restored = try reconcileSessionState(controller, reload: reader.reload())
        try expectReplayWinners(restored.sessions, ["slot-second"], now: now)
        try sessionExpect(restored.orderingKnown, "the complete replay should prove the shared-slot order")
        try expectReplayWinners(store.load().currentSessions(now: now), ["slot-second"], now: now)
        let restarted = try SessionStateController(
            storeDirectory: directory,
            eventsURL: eventsURL,
            clock: { now }
        )
        let snapshot = try reconcileSessionState(restarted, reload: EventLogReader(url: eventsURL).reload())
        try expectReplayWinners(snapshot.sessions, ["slot-second"], now: now)
        try sessionExpect(
            snapshot.sessions.map(\.evidenceOrdinal) == restored.sessions.map(\.evidenceOrdinal),
            "an unchanged replay after restart should retain the established ordinals"
        )
    }

    private static func testReplayOrderingCoverage() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_710)
        let events = try terminalSlotDismissalEvents(now: now)
        let olderFirst = try sessionEvent(
            id: "older-first",
            sessionID: "slot-first",
            status: "done",
            hookEvent: "agentStop",
            timestamp: now.addingTimeInterval(-1)
        )
        let cases: [ReplayOrderingCase] = [
            .init(initial: [events[1]], replay: events, winners: ["slot-second"], known: true),
            .init(initial: events, replay: [events[0]], winners: ["slot-second"], known: true),
            .init(
                initial: [events[1]], replay: [events[0]],
                winners: ["slot-first", "slot-second"], known: false
            ),
            .init(initial: [events[1], events[0]], replay: events, winners: ["slot-second"], known: true),
            .init(initial: [olderFirst, events[1]], replay: events, winners: ["slot-second"], known: true)
        ]
        for fixture in cases {
            try assertReplayOrdering(fixture, now: now)
        }
    }

    private static func assertReplayOrdering(_ fixture: ReplayOrderingCase, now: Date) throws {
        var index = SessionStateIndex.rebuilding(from: fixture.initial, now: now)
        let prior = index.persistedRecords
        _ = index.rebuildOrdering(from: fixture.replay, now: now)
        try expectReplayWinners(index.currentSessions(now: now), fixture.winners, now: now)
        try sessionExpect(
            index.orderingNeedsRebuild == !fixture.known,
            "only a proven replay order should clear the rebuild gate"
        )
        if !fixture.known {
            try sessionExpect(
                index.persistedRecords.first { $0.identity.sessionID == "slot-second" } == prior.first,
                "an incomplete replay must retain the absent session's proven ordering and metadata"
            )
            try sessionExpect(
                index.dismiss(dismissalRequest(for: fixture.replay[0]), now: now) == .orderingUnavailable,
                "unproven recovered evidence must not become dismissible"
            )
        }
        try expectReplayRoundTrip(index)
    }

    private static func testReplayOrderingPreservesDismissal() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_720)
        let events = try terminalSlotDismissalEvents(now: now)
        var index = SessionStateIndex.rebuilding(from: [events[1]], now: now)
        try expectReplayWinners(index.currentSessions(now: now), ["slot-second"], now: now)
        try sessionExpect(
            index.dismiss(dismissalRequest(for: events[1]), now: now) == .dismissed,
            "the known winner should be dismissible before recovery"
        )
        let prior = try sessionRequire(index.persistedRecords.first, "the dismissed winner should be stored")
        _ = index.rebuildOrdering(from: events, now: now)
        let winner = try sessionRequire(
            index.persistedRecords.first { $0.identity == prior.identity },
            "recovery should retain the dismissed winner"
        )
        try sessionExpect(
            winner.dismissedEvidenceID == prior.dismissedEvidenceID &&
                winner.equivalentEvidenceIDs == prior.equivalentEvidenceIDs &&
                winner.statusChangedAt == prior.statusChangedAt &&
                winner.context == prior.context,
            "realigning ordinals must preserve dismissal, tie evidence, attention rounds, and return metadata"
        )
        try expectReplayWinners(index.currentSessions(now: now), [], now: now)
        try expectReplayRoundTrip(index)
    }
}

private extension MewsAppModelTests {
    private static func testReplayOrderingIsolatesOtherTimestamps() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_730)
        let events = try terminalSlotDismissalEvents(now: now)
        let independent = try independentReplayEvent(now: now.addingTimeInterval(1))
        var index = SessionStateIndex.rebuilding(from: [events[1], independent], now: independent.timestamp)
        let prior = index.persistedRecords.first { $0.identity == eventIdentity(independent) }
        _ = index.rebuildOrdering(from: events, now: independent.timestamp)
        try sessionExpect(
            !index.orderingNeedsRebuild &&
                index.persistedRecords.first { $0.identity == eventIdentity(independent) } == prior,
            "an absent record with a different timestamp must not block recovery or lose its metadata"
        )
        try expectReplayWinners(
            index.currentSessions(now: independent.timestamp),
            ["independent", "slot-second"],
            now: independent.timestamp
        )
        try expectReplayRoundTrip(index)
    }

    private static func testIncompleteReplayRejectsConflictingOrder() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_740)
        let events = try terminalSlotDismissalEvents(now: now)
        let independent = try independentReplayEvent(now: now)
        var index = SessionStateIndex.rebuilding(from: [events[1], events[0], independent], now: now)
        let prior = index.persistedRecords.first { $0.identity == eventIdentity(independent) }
        _ = index.rebuildOrdering(from: events, now: now)
        try sessionExpect(
            index.orderingNeedsRebuild &&
                index.persistedRecords.filter { !$0.orderingKnown }.count == 2 &&
                index.persistedRecords.first { $0.identity == eventIdentity(independent) } == prior,
            "conflicting replay order must remain unknown when another ordered record is absent"
        )
        try expectReplayWinners(
            index.currentSessions(now: now),
            ["independent", "slot-first", "slot-second"],
            now: now
        )
        try expectReplayRoundTrip(index)
    }

    private static func testReplayOrderingReservesOrdinalCapacity() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_750)
        let events = try terminalSlotDismissalEvents(now: now)
        let independent = try independentReplayEvent(now: now.addingTimeInterval(1))
        let initial = SessionStateIndex.rebuilding(from: [events[1], independent], now: independent.timestamp)
        var index = try SessionStateIndex(
            restoring: initial.persistedRecords,
            nextEvidenceOrdinal: UInt64.max - 2,
            orderingNeedsRebuild: false
        )
        _ = index.rebuildOrdering(from: events, now: independent.timestamp)
        try expectReplayWinners(
            index.currentSessions(now: independent.timestamp),
            ["independent", "slot-second"],
            now: independent.timestamp
        )
        try sessionExpect(
            Set(index.persistedRecords.compactMap(\.evidenceOrdinal)).count == index.count,
            "projection compaction must not reuse retained evidence ordinals"
        )
        try expectReplayRoundTrip(index)
    }

    private static func independentReplayEvent(now: Date) throws -> MewsEvent {
        try sessionEvent(
            id: "independent",
            sessionID: "independent",
            status: "done",
            hookEvent: "agentStop",
            timestamp: now
        )
    }

    private static func expectReplayWinners(
        _ sessions: [CurrentSessionState],
        _ expected: [String],
        now: Date
    ) throws {
        let actual = SessionPresentationPolicy.resolve(
            sessions: sessions,
            attentionRecords: [],
            healthSnapshot: nil,
            now: now
        ).rows.map { $0.identity.sessionID }.sorted()
        try sessionExpect(actual == expected, "expected replay winners \(expected), got \(actual)")
    }

    private static func expectReplayRoundTrip(_ index: SessionStateIndex) throws {
        let directory = try sessionScratchDirectory("replay-ordering-round-trip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStateStore(url: directory.appendingPathComponent("sessions.json"))
        try store.save(index)
        try sessionExpect(try store.load() == index, "replay ordering must survive validated persistence")
    }
}

private struct ReplayOrderingCase {
    let initial: [MewsEvent]
    let replay: [MewsEvent]
    let winners: [String]
    let known: Bool
}
