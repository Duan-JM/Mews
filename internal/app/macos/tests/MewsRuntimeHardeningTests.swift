import Foundation

extension MewsAppModelTests {
    static func testPresentationFreshness() throws {
        try testActivePresentationFreshness()
        try testSettledPresentationFreshness()
        try testPresentationClockSafety()
    }

    static func testAgentRestartBackoff() throws {
        try testEscalatingAgentRetry()
        try testMaximumAgentRetry()
        try testStableAgentRetryReset()
        try testAgentProcessOwnership()
        try testAgentSocketPath()
        try testAgentProcessEnvironment()
    }

    static func testRuntimeHealthSnapshot() throws {
        let fixturePath = try hardeningRequire(
            ProcessInfo.processInfo.environment["MEWS_GO_HEALTH_FIXTURE"],
            "Go runtime-health fixture path should be provided"
        )
        let snapshot = try RuntimeHealthSnapshotReader(
            url: URL(fileURLWithPath: fixturePath)
        ).load()
        try hardeningExpect(snapshot.version == 1, "the app should decode the Go snapshot version")
        try hardeningExpect(snapshot.state == .checking, "the app should decode the CLI health state")
        try hardeningExpect(
            snapshot.affectedCapabilities.map { $0.id } == ["notifications"],
            "the app should expose only affected capabilities"
        )
        let capability = try hardeningRequire(
            snapshot.affectedCapabilities.first,
            "Go fixture should include an affected capability"
        )
        try hardeningExpect(
            capability.transitionFrom == .ready &&
                capability.transitionTarget == .degraded &&
                capability.transitionCount == 1,
            "the app should decode Go transition metadata"
        )
        try hardeningExpect(
            snapshot.checkedAt.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) > 0,
            "the app should decode Go fractional RFC3339 timestamps"
        )
        try hardeningExpect(
            snapshot.effectiveState(at: snapshot.validUntil.addingTimeInterval(-1)) == .checking,
            "a current snapshot should preserve its policy state"
        )
        try hardeningExpect(
            snapshot.effectiveState(at: snapshot.validUntil.addingTimeInterval(1)) == .checking,
            "a stale snapshot should return to checking instead of showing old health"
        )
        try hardeningExpect(
            snapshot.effectiveState(
                at: snapshot.checkedAt.addingTimeInterval(-RuntimeHealthSnapshot.futureTolerance - 1)
            ) == .checking,
            "a materially future-dated snapshot should return to checking"
        )
        try testRuntimeHealthValidityWindows()
        try testUnsupportedRuntimeHealthVersion(fixturePath: fixturePath)
    }

    private static func testRuntimeHealthValidityWindows() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let valid = RuntimeHealthSnapshot(
            version: RuntimeHealthSnapshot.currentVersion,
            state: .ready,
            summary: "ready",
            checkedAt: checkedAt,
            validUntil: checkedAt.addingTimeInterval(RuntimeHealthSnapshot.lifetime),
            capabilities: []
        )
        try hardeningExpect(
            valid.effectiveState(at: checkedAt) == .ready,
            "a bounded validity window should preserve snapshot state"
        )

        let overlong = RuntimeHealthSnapshot(
            version: valid.version,
            state: valid.state,
            summary: valid.summary,
            checkedAt: checkedAt,
            validUntil: checkedAt.addingTimeInterval(RuntimeHealthSnapshot.lifetime + 1),
            capabilities: []
        )
        try hardeningExpect(
            overlong.effectiveState(at: checkedAt) == .checking,
            "an overlong validity window should return to checking"
        )

        let reversed = RuntimeHealthSnapshot(
            version: valid.version,
            state: valid.state,
            summary: valid.summary,
            checkedAt: checkedAt,
            validUntil: checkedAt.addingTimeInterval(-1),
            capabilities: []
        )
        try hardeningExpect(
            reversed.effectiveState(at: checkedAt) == .checking,
            "a reversed validity window should return to checking"
        )
    }

    private static func testUnsupportedRuntimeHealthVersion(fixturePath: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        var object = try hardeningRequire(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Go runtime-health fixture should decode as an object"
        )
        object["version"] = RuntimeHealthSnapshot.currentVersion + 1
        let unsupported = try JSONSerialization.data(withJSONObject: object)

        do {
            _ = try RuntimeHealthSnapshotDecoder.decode(unsupported)
            throw MewsRuntimeHardeningTestFailure(message: "unsupported health version was accepted")
        } catch let error as RuntimeHealthSnapshotDecodingError {
            try hardeningExpect(
                error == .unsupportedVersion(RuntimeHealthSnapshot.currentVersion + 1),
                "the app should report the unsupported health version"
            )
        }
    }

    static func testNotificationStatusRecord() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000.125)
        let data = try NotificationStatusRecord(
            status: "authorized",
            checkedAt: checkedAt
        ).encoded()
        let object = try hardeningRequire(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "notification status should encode as an object"
        )

        try hardeningExpect(object["status"] as? String == "authorized", "status should be encoded")
        try hardeningExpect(
            object["checked_at"] is String,
            "notification status should include its check timestamp"
        )
        try hardeningExpect(
            NotificationHealthTiming.refreshInterval == 30 &&
                NotificationHealthTiming.staleAfter == 90,
            "notification refresh and stale timing should stay bounded"
        )
    }

    private static func testEscalatingAgentRetry() throws {
        var backoff = AgentRestartBackoff()

        try hardeningExpect(backoff.shouldAttempt(at: 0), "the first agent start should run immediately")
        backoff.recordFailure(at: 0)
        try hardeningExpect(
            !backoff.shouldAttempt(at: AgentRestartBackoff.baseRetryDelay - 1),
            "a failed helper should not restart every event-poll tick"
        )
        try hardeningExpect(
            backoff.shouldAttempt(at: AgentRestartBackoff.baseRetryDelay),
            "agent restart should resume after the bounded retry delay"
        )
        backoff.recordFailure(at: AgentRestartBackoff.baseRetryDelay)
        try hardeningExpect(
            !backoff.shouldAttempt(at: AgentRestartBackoff.baseRetryDelay * 3 - 1),
            "consecutive failures should increase the retry delay"
        )
    }

    private static func testActivePresentationFreshness() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = try decodePresentationEvent(
            status: "running",
            timestamp: now.addingTimeInterval(-MewsPresentationFreshness.activeLifetime + 1)
        )
        let stale = try decodePresentationEvent(
            status: "needs_input",
            timestamp: now.addingTimeInterval(-MewsPresentationFreshness.activeLifetime - 1)
        )

        try hardeningExpect(
            currentPrimaryEvent(in: [recent], now: now)?.id == recent.id,
            "active state should remain current for 24 hours"
        )
        try hardeningExpect(
            currentPrimaryEvent(in: [stale], now: now) == nil,
            "stale active state should return to idle"
        )
    }

    private static func testSettledPresentationFreshness() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = try decodePresentationEvent(
            status: "done",
            timestamp: now.addingTimeInterval(-MewsPresentationFreshness.settledLifetime + 1)
        )
        let stale = try decodePresentationEvent(
            status: "failed",
            timestamp: now.addingTimeInterval(-MewsPresentationFreshness.settledLifetime - 1)
        )

        try hardeningExpect(
            currentPrimaryEvent(in: [recent], now: now)?.id == recent.id,
            "recent terminal state should remain visible for 30 minutes"
        )
        try hardeningExpect(
            currentPrimaryEvent(in: [stale], now: now) == nil,
            "stale terminal state should return to idle"
        )
    }

    private static func testPresentationClockSafety() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let invalidFuture = try decodePresentationEvent(
            status: "needs_input",
            timestamp: now.addingTimeInterval(MewsPresentationFreshness.futureTolerance + 1)
        )
        let recentRunning = try decodePresentationEvent(
            status: "running",
            timestamp: now.addingTimeInterval(-60)
        )
        let staleDone = try decodePresentationEvent(
            status: "done",
            timestamp: now.addingTimeInterval(-MewsPresentationFreshness.settledLifetime - 1)
        )

        try hardeningExpect(
            currentPrimaryEvent(in: [invalidFuture], now: now) == nil,
            "events too far in the future should not stick indefinitely"
        )
        try hardeningExpect(
            currentPrimaryEvent(in: [recentRunning, staleDone], now: now) == nil,
            "an invalid latest transition should not resurrect an earlier state"
        )
        try hardeningExpect(
            MewsPresentationState(event: currentPrimaryEvent(in: [], now: now)).status == .idle,
            "an empty event log should present as idle"
        )
    }

    private static func testMaximumAgentRetry() throws {
        var backoff = AgentRestartBackoff()
        var uptime: TimeInterval = 0
        for delay in [10, 20, 40, 80, 160, 300, 300] {
            backoff.recordFailure(at: uptime)
            try hardeningExpect(
                !backoff.shouldAttempt(at: uptime + TimeInterval(delay) - 1),
                "retry delay should not fire before its deadline"
            )
            uptime += TimeInterval(delay)
            try hardeningExpect(
                backoff.shouldAttempt(at: uptime),
                "retry delay should stay capped at five minutes"
            )
        }
    }

    private static func testStableAgentRetryReset() throws {
        var backoff = AgentRestartBackoff()
        backoff.recordFailure(at: 0)
        backoff.recordFailure(at: AgentRestartBackoff.baseRetryDelay)
        backoff.recordStarted(at: 100)
        let stableExit = 100 + AgentRestartBackoff.stabilityInterval
        backoff.recordFailure(at: stableExit)
        try hardeningExpect(
            backoff.shouldAttempt(at: stableExit + AgentRestartBackoff.baseRetryDelay),
            "one healthy minute should reset retry escalation"
        )
    }

    private static func testAgentProcessOwnership() throws {
        var coordinator = AgentProcessCoordinator()
        try hardeningExpect(
            coordinator.shouldProbeSocket(childIsRunning: false, uptime: 0),
            "initial startup should probe before launching a child"
        )
        try hardeningExpect(
            coordinator.action(
                childIsRunning: false,
                socketResponsive: true,
                uptime: 0
            ) == .none &&
                coordinator.ownership == .external,
            "a responsive existing socket should suppress duplicate child launches"
        )
        try hardeningExpect(
            coordinator.action(
                childIsRunning: false,
                socketResponsive: false,
                uptime: 2
            ) == .launch,
            "a disappeared external agent should trigger immediate recovery"
        )
        coordinator.recordStarted(at: 2)
        try hardeningExpect(
            !coordinator.shouldProbeSocket(childIsRunning: true, uptime: 4),
            "an owned running child should not receive redundant socket probes"
        )
        try hardeningExpect(
            coordinator.action(
                childIsRunning: false,
                socketResponsive: true,
                uptime: 5
            ) == .none &&
                coordinator.ownership == .external,
            "a healthy external agent should take over after the child exits"
        )
    }

    private static func testAgentSocketPath() throws {
        let shortHome = URL(fileURLWithPath: "/Users/mews")
        try hardeningExpect(
            AgentSocketPath.resolve(
                homeURL: shortHome,
                temporaryDirectory: URL(fileURLWithPath: "/tmp/probe"),
                userID: 501,
                namespace: nil
            ) == "/Users/mews/Library/Application Support/Mews/mews.sock",
            "short homes should use the Application Support socket"
        )

        let longHome = URL(fileURLWithPath: "/" + String(repeating: "a", count: 100))
        try hardeningExpect(
            AgentSocketPath.resolve(
                homeURL: longHome,
                temporaryDirectory: URL(fileURLWithPath: "/tmp/probe"),
                userID: 501,
                namespace: "probe"
            ) == "/tmp/probe/mews-501-f97691246db266f1/mews.sock",
            "long homes should match the CLI short-path namespace"
        )
    }

    private static func testAgentProcessEnvironment() throws {
        let base = [
            "HOME": "/Users/mews",
            "MEWS_APP_PATH": "/old/Mews.app",
            "PRESERVED": "value"
        ]
        let environment = AgentProcessEnvironment.merging(
            base,
            appPath: "/Applications/Mews.app"
        )

        try hardeningExpect(
            environment["MEWS_APP_PATH"] == "/Applications/Mews.app",
            "the bundled helper should receive the enclosing app path"
        )
        try hardeningExpect(
            environment["HOME"] == base["HOME"] &&
                environment["PRESERVED"] == base["PRESERVED"] &&
                environment.count == base.count,
            "the helper app-path override should preserve the current environment"
        )
    }

    private static func decodePresentationEvent(
        status: String,
        timestamp: Date
    ) throws -> MewsEvent {
        let object: [String: Any] = [
            "id": UUID().uuidString,
            "source": "copilot",
            "status": status,
            "agent_scope": "main",
            "timestamp": ISO8601DateFormatter().string(from: timestamp)
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MewsEvent.self, from: data)
    }

    private static func hardeningExpect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw MewsRuntimeHardeningTestFailure(message: message)
        }
    }

    private static func hardeningRequire<T>(
        _ value: T?,
        _ message: String
    ) throws -> T {
        guard let value else {
            throw MewsRuntimeHardeningTestFailure(message: message)
        }
        return value
    }
}

private struct MewsRuntimeHardeningTestFailure: Error {
    let message: String
}
