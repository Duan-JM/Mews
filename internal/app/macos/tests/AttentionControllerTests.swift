import Foundation

extension MewsAppModelTests {
    static func testAttentionControllerBehavior() throws {
        try testAttentionControllerWiring()
        try testAttentionControllerExpiry()
    }

    private static func testAttentionControllerWiring() throws {
        let directory = try sessionScratchDirectory("attention-controller")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = attentionControllerTime(200)
        let controller = try AttentionControllerHarness(
            storeDirectory: directory,
            clock: { now.addingTimeInterval(30) }
        )
        let first = try reconcileInitialAttention(controller, now: now)
        let replay = try reconcileAttentionEvent(
            controller,
            id: "controller-done-duplicate",
            status: "done",
            timestamp: now.addingTimeInterval(1)
        )
        let resolved = try reconcileAttentionEvent(
            controller,
            id: "controller-running",
            status: "running",
            timestamp: now.addingTimeInterval(2)
        )
        let nextRound = try reconcileAttentionEvent(
            controller,
            id: "controller-next-done",
            status: "done",
            timestamp: now.addingTimeInterval(3)
        )
        let rotatedReplay = try reconcileRotatedAttention(
            directory: directory,
            now: now,
            prior: controller
        )

        try controllerExpect(first.reconciliation.newlyAlertable.count == 1, "initial attention should alert")
        try controllerExpect(replay.reconciliation.newlyAlertable.isEmpty, "duplicate evidence should stay silent")
        try controllerExpect(
            resolved.reconciliation.resolvedNotificationIdentifiers.count == 1,
            "running should resolve prior attention"
        )
        try controllerExpect(nextRound.reconciliation.newlyAlertable.count == 1, "later done should re-alert")
        try controllerExpect(
            rotatedReplay.reconciliation.newlyAlertable.isEmpty,
            "restart and rotation should preserve delivery state"
        )
    }

    private static func testAttentionControllerExpiry() throws {
        let directory = try sessionScratchDirectory("attention-expiry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventTime = attentionControllerTime(300)
        var currentTime = eventTime
        let controller = try AttentionControllerHarness(
            storeDirectory: directory,
            clock: { currentTime }
        )
        let delivered = try reconcileStartupAttentionEvent(
            controller,
            id: "expiry-done",
            sessionID: "expiry",
            status: "done",
            timestamp: eventTime
        )
        currentTime = eventTime.addingTimeInterval(31 * 60)
        let expired = try controller.reconcile(EventReload(events: [], newEvents: []))

        try controllerExpect(delivered.reconciliation.activeCount == 1, "fresh attention should be active")
        try controllerExpect(expired.reconciliation.activeCount == 0, "expired attention should be inactive")
        try controllerExpect(
            expired.reconciliation.resolvedNotificationIdentifiers.count == 1,
            "expiry should remove the delivered notification"
        )
    }

    private static func reconcileInitialAttention(
        _ controller: AttentionControllerHarness,
        now: Date
    ) throws -> AttentionRuntimeUpdate {
        let events = [
            try sessionEvent(id: "controller-done", sessionID: "controller", status: "done", timestamp: now),
            try sessionEvent(
                id: "controller-subagent",
                sessionID: "subagent",
                status: "done",
                agentScope: "subagent",
                timestamp: now
            ),
            try sessionEvent(
                id: "controller-recoverable",
                sessionID: "recoverable",
                status: "failed",
                recoverable: true,
                timestamp: now
            )
        ]
        return try controller.reconcile(
            EventReload(events: events, newEvents: [], recoveryEvents: events)
        )
    }

    private static func reconcileRotatedAttention(
        directory: URL,
        now: Date,
        prior: AttentionControllerHarness
    ) throws -> AttentionRuntimeUpdate {
        let restarted = try AttentionControllerHarness(
            storeDirectory: directory,
            clock: { now.addingTimeInterval(30) },
            index: prior.index,
            didReconcile: true
        )
        return try reconcileStartupAttentionEvent(
            restarted,
            id: "controller-rotated-duplicate",
            status: "done",
            timestamp: now.addingTimeInterval(4)
        )
    }

    private static func reconcileAttentionEvent(
        _ controller: AttentionControllerHarness,
        id: String,
        sessionID: String = "controller",
        status: String,
        timestamp: Date
    ) throws -> AttentionRuntimeUpdate {
        let event = try sessionEvent(
            id: id,
            sessionID: sessionID,
            status: status,
            timestamp: timestamp
        )
        return try controller.reconcile(
            EventReload(
                events: [event],
                newEvents: [event]
            )
        )
    }

    private static func reconcileStartupAttentionEvent(
        _ controller: AttentionControllerHarness,
        id: String,
        sessionID: String = "controller",
        status: String,
        timestamp: Date
    ) throws -> AttentionRuntimeUpdate {
        let event = try sessionEvent(
            id: id,
            sessionID: sessionID,
            status: status,
            timestamp: timestamp
        )
        return try controller.reconcile(
            EventReload(
                events: [event],
                newEvents: [],
                recoveryEvents: [event]
            )
        )
    }
}

private final class AttentionControllerHarness {
    let controller: AttentionController
    var index: SessionStateIndex
    private let clock: () -> Date
    private var didReconcile: Bool

    init(
        storeDirectory: URL,
        clock: @escaping () -> Date,
        index: SessionStateIndex = SessionStateIndex(),
        didReconcile: Bool = false
    ) throws {
        controller = try AttentionController(storeDirectory: storeDirectory)
        self.clock = clock
        self.index = index
        self.didReconcile = didReconcile
    }

    func reconcile(_ reload: EventReload) throws -> AttentionRuntimeUpdate {
        let events: [MewsEvent]
        if reload.sessionDidResync {
            events = reload.sessionResyncEvents
        } else if didReconcile {
            events = reload.newEvents
        } else {
            events = reload.recoveryEvents
        }
        if reload.sessionDidResync {
            _ = index.rebuildOrdering(from: events, now: clock())
        } else {
            _ = index.apply(events, now: clock())
        }
        didReconcile = true
        return try controller.reconcile(
            reload,
            sessions: index.currentSessions(now: clock())
        )
    }
}

private func attentionControllerTime(_ offset: TimeInterval) -> Date {
    return Date(timeIntervalSince1970: 1_800_100_000 + offset)
}

private func controllerExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw AttentionControllerTestFailure(message: message)
    }
}

private struct AttentionControllerTestFailure: Error {
    let message: String
}
