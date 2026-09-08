import Foundation

extension MewsAppModelTests {
    static func testRecoverableSessionStateStore() throws {
        try testInitialRecoveryUsesFullEventScan()
        try testResyncPreservesNewStopTransitions()
        try testSessionIndexRestartRecovery()
        try testRestartReconcilesOfflineEvidence()
        try testFutureEvidenceAdmission()
        try testPersistedFutureReplacement()
        try testSessionIndexCorruptionRecovery()
        try testMalformedPrecedenceIsCorrupt()
        try testMixedInvalidContextIsCorrupt()
        try testDeterministicSessionExpiry()
    }

    private static func testInitialRecoveryUsesFullEventScan() throws {
        let directory = try sessionScratchDirectory("initial-recovery")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_250)
        let events = try (0..<12).map { index in
            try sessionEvent(
                id: "initial-\(index)",
                sessionID: "session-\(index)",
                status: "running",
                timestamp: now.addingTimeInterval(TimeInterval(index))
            )
        }
        let store = SessionStateStore(url: directory.appendingPathComponent("sessions.json"))
        let repository = try SessionStateRepository(store: store, clock: { now.addingTimeInterval(20) })
        let reload = EventReload(
            events: Array(events.suffix(10)),
            newEvents: [],
            recoveryEvents: events
        )

        try sessionExpect(try repository.apply(reload), "initial recovery should accept the retained event scan")
        try sessionExpect(repository.sessionCount == 12, "initial recovery should not inherit the UI history limit")
    }

    private static func testSessionIndexRestartRecovery() throws {
        let directory = try sessionScratchDirectory("restart")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStateStore(url: directory.appendingPathComponent("sessions.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_300)
        let cliPath = "/Applications/Mews.app/Contents/Resources/mw"
        let repository = try SessionStateRepository(
            store: store,
            clock: { now },
            cliExecutablePath: cliPath
        )
        let initialEvents = try restartSessionEvents(now: now)
        try sessionExpect(
            try repository.apply(EventReload(events: initialEvents, newEvents: [])),
            "accepted evidence should persist atomically"
        )
        try sessionExpect(repository.sessionCount == 2, "repository should retain both sessions")
        try assertPrivateStorePermissions(store)
        let persistedText = try sessionRequire(
            String(data: Data(contentsOf: store.url), encoding: .utf8),
            "the persisted session index should be UTF-8 JSON"
        )
        try sessionExpect(
            !persistedText.contains("return_command"),
            "the index should derive Mews-owned commands instead of persisting command text"
        )

        let restarted = try SessionStateRepository(
            store: SessionStateStore(url: store.url),
            clock: { now },
            cliExecutablePath: cliPath
        )
        try sessionExpect(restarted.sessionCount == 2, "a new repository should recover both sessions")
        try assertRestartedContext(restarted)
    }

    private static func assertPrivateStorePermissions(_ store: SessionStateStore) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        try sessionExpect(
            attributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o600),
            "the Mews-owned session index should be private"
        )
    }

    private static func assertRestartedContext(_ restarted: SessionStateRepository) throws {
        let identity = try sessionRequire(
            SessionIdentity(source: "claude-code", sessionID: "restart-b"),
            "restored identity should be valid"
        )
        let restored = try sessionRequire(
            restarted.currentSession(for: identity),
            "restored session should be readable"
        )
        try sessionExpect(restored.status == .needsInput, "restart should preserve session state")
        try sessionExpect(
            restored.returnContext?.returnCommand ==
                "'/Applications/Mews.app/Contents/Resources/mw' history --session 'restart-b'",
            "restart should preserve the Mews-generated return command"
        )
        try sessionExpect(
            restored.returnContext?.kittyTarget?.windowID == "17",
            "restart should preserve validated terminal metadata"
        )
    }

    private static func testRestartReconcilesOfflineEvidence() throws {
        let directory = try sessionScratchDirectory("offline-recovery")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStateStore(url: directory.appendingPathComponent("sessions.json"))
        let start = Date(timeIntervalSince1970: 1_800_000_350)
        let repository = try SessionStateRepository(store: store, clock: { start })
        let initial = try offlineRecoveryInitialEvents(start: start)
        _ = try repository.apply(initial)

        let restarted = try SessionStateRepository(
            store: SessionStateStore(url: store.url),
            clock: { start.addingTimeInterval(20) }
        )
        let offline = try sessionEvent(
            id: "offline-b-done",
            sessionID: "offline-b",
            status: "done",
            timestamp: start.addingTimeInterval(10)
        )
        try sessionExpect(
            try restarted.apply(EventReload(events: [offline], newEvents: [], recoveryEvents: [offline])),
            "startup recovery should reconcile events appended while the app was offline"
        )
        try sessionExpect(restarted.sessionCount == 2, "bounded recovery should preserve absent persisted sessions")
        try assertOfflineRecoveryStates(restarted)
    }

    private static func assertOfflineRecoveryStates(_ repository: SessionStateRepository) throws {
        let first = try sessionRequire(
            SessionIdentity(source: "copilot", sessionID: "offline-a"),
            "first offline identity should be valid"
        )
        let second = try sessionRequire(
            SessionIdentity(source: "copilot", sessionID: "offline-b"),
            "second offline identity should be valid"
        )
        try sessionExpect(
            repository.currentSession(for: first)?.evidenceStatus == .running,
            "sessions absent from the bounded log should remain recovered"
        )
        try sessionExpect(
            repository.currentSession(for: second)?.evidenceStatus == .done,
            "new offline evidence should update its persisted session"
        )
    }

    private static func testFutureEvidenceAdmission() throws {
        let directory = try sessionScratchDirectory("future-admission")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_375)
        let repository = try SessionStateRepository(
            store: SessionStateStore(url: directory.appendingPathComponent("sessions.json")),
            clock: { now }
        )
        let future = try sessionEvent(
            id: "future-new",
            sessionID: "future-new",
            status: "running",
            timestamp: now.addingTimeInterval(SessionFreshnessPolicy.standard.futureTolerance + 1)
        )

        try sessionExpect(!repository.apply([future]), "too-future repository evidence should be rejected")
        try sessionExpect(repository.sessionCount == 0, "rejected future evidence should not poison the index")

        let recoveryStore = SessionStateStore(
            url: directory.appendingPathComponent("recovered-sessions.json")
        )
        let recovered = try recoveryStore.recover(from: [future], now: now)
        try sessionExpect(recovered.count == 0, "explicit recovery should reject too-future evidence")
    }

    private static func testPersistedFutureReplacement() throws {
        let directory = try sessionScratchDirectory("future-replacement")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sessions.json")
        let now = Date(timeIntervalSince1970: 1_800_000_390)
        let futureTime = now.addingTimeInterval(SessionFreshnessPolicy.standard.futureTolerance + 60)
        let future = try sessionEvent(
            id: "persisted-future",
            sessionID: "future-session",
            status: "running",
            timestamp: futureTime
        )
        let seed = try SessionStateRepository(
            store: SessionStateStore(url: url),
            clock: { futureTime }
        )
        _ = try seed.apply([future])

        let current = try sessionEvent(
            id: "valid-current",
            sessionID: "future-session",
            status: "needs_input",
            timestamp: now
        )
        let restarted = try SessionStateRepository(
            store: SessionStateStore(url: url),
            clock: { now }
        )
        try sessionExpect(
            try restarted.apply([current]),
            "valid current evidence should replace a persisted too-future record"
        )
        try sessionExpect(
            restarted.currentSessions().first?.evidenceAt == now,
            "replacement should remove the future evidence timestamp"
        )
    }

    private static func testSessionIndexCorruptionRecovery() throws {
        let directory = try sessionScratchDirectory("corruption")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sessions.json")
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: url)
        let store = SessionStateStore(url: url)

        do {
            _ = try store.load()
            throw SessionTestFailure(message: "corrupt session storage should fail explicitly")
        } catch let error as SessionStateStoreError {
            guard case .corruptData = error else {
                throw SessionTestFailure(message: "corrupt session storage should report corruptData")
            }
        }
        try sessionExpect(
            try Data(contentsOf: url) == corrupt,
            "a failed read should leave corrupt evidence untouched for diagnosis"
        )
        try rebuildCorruptSessionStore(store)
    }

    private static func rebuildCorruptSessionStore(_ store: SessionStateStore) throws {
        let event = try sessionEvent(
            id: "recovered",
            sessionID: "recovered",
            status: "running",
            timestamp: Date(timeIntervalSince1970: 1_800_000_400)
        )
        let recovered = try store.recover(
            from: EventReload(events: [event], newEvents: []),
            now: event.timestamp,
            cliExecutablePath: "/opt/mews/bin/mw"
        )
        try sessionExpect(recovered.count == 1, "explicit recovery should rebuild from validated history")
        try sessionExpect(try store.load().count == 1, "rebuilt storage should be readable after recovery")
    }

    private static func testMalformedPrecedenceIsCorrupt() throws {
        let directory = try sessionScratchDirectory("precedence-corruption")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStateStore(url: directory.appendingPathComponent("sessions.json"))
        let event = try sessionEvent(
            id: "precedence",
            sessionID: "precedence",
            status: "running",
            timestamp: Date(timeIntervalSince1970: 1_800_000_450)
        )
        _ = try store.recover(from: [event], now: event.timestamp)
        try overwritePrecedence(in: store.url, value: 500)

        do {
            _ = try store.load()
            throw SessionTestFailure(message: "inconsistent persisted precedence should be rejected")
        } catch let error as SessionStateStoreError {
            guard case .corruptData = error else {
                throw SessionTestFailure(message: "invalid precedence should report corruptData")
            }
        }
    }

    private static func overwritePrecedence(in url: URL, value: Int) throws {
        let data = try Data(contentsOf: url)
        var object = try sessionRequire(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "session snapshot should decode as an object"
        )
        var sessions = try sessionRequire(
            object["sessions"] as? [[String: Any]],
            "session snapshot should contain records"
        )
        sessions[0]["evidencePrecedence"] = value
        object["sessions"] = sessions
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private static func testDeterministicSessionExpiry() throws {
        let directory = try sessionScratchDirectory("expiry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStateStore(url: directory.appendingPathComponent("sessions.json"))
        let start = Date(timeIntervalSince1970: 1_800_000_500)
        var now = start
        let repository = try SessionStateRepository(store: store, clock: { now })
        _ = try repository.apply(expiryEvents(start: start))
        let persisted = try Data(contentsOf: store.url)

        now = start.addingTimeInterval(SessionFreshnessPolicy.standard.settledLifetime + 1)
        try assertSettledSessionExpired(repository)
        now = start.addingTimeInterval(SessionFreshnessPolicy.standard.activeLifetime)
        try assertActiveSessionAtBoundary(repository)
        now.addTimeInterval(1)
        try assertActiveSessionExpired(repository)
        try sessionExpect(
            try Data(contentsOf: store.url) == persisted,
            "clock-driven expiry should not rewrite the persisted index or raw event history"
        )
    }

    private static func assertSettledSessionExpired(_ repository: SessionStateRepository) throws {
        let identity = try sessionRequire(
            SessionIdentity(source: "copilot", sessionID: "settled"),
            "settled identity should be valid"
        )
        let settled = try sessionRequire(
            repository.currentSession(for: identity),
            "settled session should remain readable after expiry"
        )
        try sessionExpect(settled.status == .idle, "settled status should use its shorter freshness lifetime")
    }

    private static func assertActiveSessionAtBoundary(_ repository: SessionStateRepository) throws {
        let identity = try sessionRequire(
            SessionIdentity(source: "copilot", sessionID: "expiring"),
            "active identity should be valid"
        )
        try sessionExpect(
            repository.currentSession(for: identity)?.status == .running,
            "active state should remain current through the freshness boundary"
        )
    }

    private static func assertActiveSessionExpired(_ repository: SessionStateRepository) throws {
        let identity = try sessionRequire(
            SessionIdentity(source: "copilot", sessionID: "expiring"),
            "expired identity should be valid"
        )
        let expired = try sessionRequire(
            repository.currentSession(for: identity),
            "expired sessions should remain available to the read interface"
        )
        try sessionExpect(expired.status == .idle, "expired active evidence should derive idle state")
        try sessionExpect(expired.evidenceStatus == .running, "expiry should not replace stored evidence")
        try sessionExpect(!expired.isFresh, "expired state should report stale evidence")
    }

    private static func restartSessionEvents(now: Date) throws -> [MewsEvent] {
        return [
            try sessionEvent(
                id: "restart-a",
                sessionID: "restart-a",
                status: "running",
                timestamp: now
            ),
            try sessionEvent(
                id: "restart-b",
                source: "claude-code",
                sessionID: "restart-b",
                status: "needs_input",
                terminal: "kitty",
                terminalWindowID: "17",
                kittyListenOn: "unix:/Users/example/kitty.sock",
                timestamp: now
            )
        ]
    }

    private static func offlineRecoveryInitialEvents(start: Date) throws -> [MewsEvent] {
        return [
            try sessionEvent(
                id: "offline-a-running",
                sessionID: "offline-a",
                status: "running",
                timestamp: start
            ),
            try sessionEvent(
                id: "offline-b-running",
                sessionID: "offline-b",
                status: "running",
                timestamp: start
            )
        ]
    }

    private static func expiryEvents(start: Date) throws -> [MewsEvent] {
        return [
            try sessionEvent(
                id: "expiring",
                sessionID: "expiring",
                status: "running",
                timestamp: start
            ),
            try sessionEvent(
                id: "settled",
                sessionID: "settled",
                status: "done",
                timestamp: start
            )
        ]
    }
}
