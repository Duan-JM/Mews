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
}

private struct MewsRuntimeHardeningTestFailure: Error {
    let message: String
}
