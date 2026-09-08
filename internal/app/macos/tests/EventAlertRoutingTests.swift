import Foundation

extension MewsAppModelTests {
    static func testAlertRoutingPolicy() throws {
        try testCurrentAlertRouting()
        try testFallbackAlertRouting()
        try testLegacyAlertRouting()
        try testAggregateNotchRouting()
        try testTransientStopDetection()
        try testUnmatchedStopFallback()
        try testReusedEventIDKeepsDistinctStopRounds()
    }

    private static func testCurrentAlertRouting() throws {
        let currentCompletion = try alertRoutingEvent(
            id: "current-completion",
            agentScope: "main"
        )

        try alertRoutingExpect(
            EventAlertRoutingPolicy.channel(
                for: currentCompletion,
                notchEvent: currentCompletion,
                physicalNotchAvailable: true
            ) == .notch,
            "the event shown at a physical notch should not also send a system notification"
        )
    }

    private static func testFallbackAlertRouting() throws {
        let currentCompletion = try alertRoutingEvent(
            id: "current-completion",
            agentScope: "main"
        )
        let olderCompletion = try alertRoutingEvent(
            id: "older-completion",
            agentScope: "main"
        )
        try alertRoutingExpect(
            EventAlertRoutingPolicy.channel(
                for: currentCompletion,
                notchEvent: currentCompletion,
                physicalNotchAvailable: false
            ) == .systemNotification,
            "an unavailable physical notch should preserve the system notification fallback"
        )
        try alertRoutingExpect(
            EventAlertRoutingPolicy.channel(
                for: olderCompletion,
                notchEvent: currentCompletion,
                physicalNotchAvailable: true
            ) == .systemNotification,
            "a new event that the notch cannot present should not be dropped"
        )
    }

    private static func testLegacyAlertRouting() throws {
        let currentCompletion = try alertRoutingEvent(
            id: "current-completion",
            agentScope: "main"
        )
        let subagentCompletion = try alertRoutingEvent(
            id: "subagent-completion",
            agentScope: "subagent"
        )
        let legacyCompletion = try alertRoutingEvent(
            id: nil,
            agentScope: "main"
        )
        try alertRoutingExpect(
            EventAlertRoutingPolicy.channel(
                for: subagentCompletion,
                notchEvent: subagentCompletion,
                physicalNotchAvailable: false
            ) == .none,
            "events excluded by the existing notification policy should remain silent"
        )
        try alertRoutingExpect(
            EventAlertRoutingPolicy.channel(
                for: legacyCompletion,
                notchEvent: legacyCompletion,
                physicalNotchAvailable: true
            ) == .notch,
            "legacy events without IDs should still use the notch when they are the current event"
        )
        try alertRoutingExpect(
            EventAlertRoutingPolicy.channel(
                for: currentCompletion,
                notchEvent: legacyCompletion,
                physicalNotchAvailable: true
            ) == .systemNotification,
            "one-sided event IDs should not suppress a notification for a different event"
        )
    }

    private static func testAggregateNotchRouting() throws {
        try alertRoutingExpect(
            AttentionAlertRoutingPolicy.channel(
                status: .done,
                candidateIsRepresented: false,
                stopTransitionIsRepresented: true,
                stopTransitionWillPresent: true,
                physicalNotchAvailable: true
            ) == .notch,
            "a generic stop pulse should represent any completion at a physical notch"
        )
        try alertRoutingExpect(
            AttentionAlertRoutingPolicy.channel(
                status: .failed,
                candidateIsRepresented: true,
                stopTransitionIsRepresented: false,
                stopTransitionWillPresent: true,
                physicalNotchAvailable: true
            ) == .systemNotification,
            "a completion without a deliverable pulse should retain notification fallback"
        )
        try alertRoutingExpect(
            AttentionAlertRoutingPolicy.channel(
                status: .needsInput,
                candidateIsRepresented: true,
                stopTransitionIsRepresented: false,
                stopTransitionWillPresent: false,
                physicalNotchAvailable: true
            ) == .notch,
            "a displayed needs-input session should use the persistent notch signal"
        )
        try alertRoutingExpect(
            AttentionAlertRoutingPolicy.channel(
                status: .needsInput,
                candidateIsRepresented: false,
                stopTransitionIsRepresented: false,
                stopTransitionWillPresent: false,
                physicalNotchAvailable: true
            ) == .systemNotification,
            "a hidden needs-input session should retain its notification fallback"
        )
    }

    private static func testTransientStopDetection() throws {
        let stopped = try alertRoutingEvent(
            id: "transient-stop",
            agentScope: "main"
        )
        let resumed = try alertRoutingEvent(
            id: "resumed",
            agentScope: "main",
            status: "running",
            timestamp: "2026-07-20T12:00:01Z"
        )
        var index = SessionStateIndex()
        let result = index.applyTrackingStopTransitions(
            [stopped, resumed],
            now: stopped.timestamp.addingTimeInterval(1)
        )
        try alertRoutingExpect(
            result.stopTransitions.count == 1 &&
                result.stopTransitionIdentifier?
                    .hasPrefix("stop-event|copilot|routing-session|done|") == true &&
                result.stopTransitionIdentifier?
                    .hasSuffix("|transient-stop") == true,
            "a stop superseded before reconciliation should still pulse the notch"
        )
        let duplicate = index.applyTrackingStopTransitions(
            [stopped],
            now: stopped.timestamp.addingTimeInterval(2)
        )
        try alertRoutingExpect(
            duplicate.stopTransitionIdentifier == nil,
            "duplicate stop evidence should not pulse the notch"
        )
        var staleIndex = SessionStateIndex()
        let stale = staleIndex.applyTrackingStopTransitions(
            [stopped],
            now: stopped.timestamp.addingTimeInterval(
                SessionFreshnessPolicy.standard.settledLifetime + 1
            )
        )
        try alertRoutingExpect(
            stale.stopTransitions.isEmpty,
            "stale completion evidence should not look like a new stop"
        )
    }

    private static func testUnmatchedStopFallback() throws {
        let stopped = try alertRoutingEvent(
            id: "fallback-stop",
            agentScope: "main"
        )
        var index = SessionStateIndex()
        let transitions = index.applyTrackingStopTransitions(
            [stopped],
            now: stopped.timestamp.addingTimeInterval(1)
        ).stopTransitions
        let candidates = transitions.map(\.candidate)
        try alertRoutingExpect(
            AttentionAlertRoutingPolicy.unmatchedStopCandidates(
                transitions: transitions,
                attentionCandidates: []
            ) == candidates,
            "a transient stop should retain fallback without a final candidate"
        )
        try alertRoutingExpect(
            AttentionAlertRoutingPolicy.unmatchedStopCandidates(
                transitions: transitions,
                attentionCandidates: candidates
            ).isEmpty,
            "a final attention candidate should cover its stop transition"
        )
    }

    private static func testReusedEventIDKeepsDistinctStopRounds() throws {
        let firstStop = try alertRoutingEvent(
            id: "reused-stop",
            agentScope: "main"
        )
        let resumed = try alertRoutingEvent(
            id: "resumed-between-stops",
            agentScope: "main",
            status: "running",
            timestamp: "2026-07-20T12:00:01Z"
        )
        let secondStop = try alertRoutingEvent(
            id: "reused-stop",
            agentScope: "main",
            timestamp: "2026-07-20T12:00:02Z"
        )
        var index = SessionStateIndex()
        let first = index.applyTrackingStopTransitions(
            [firstStop, resumed],
            now: secondStop.timestamp
        )
        let second = index.applyTrackingStopTransitions(
            [secondStop],
            now: secondStop.timestamp
        )
        try alertRoutingExpect(
            first.stopTransitionIdentifier != second.stopTransitionIdentifier,
            "reused event IDs should not collapse distinct stopped rounds"
        )
    }
}

private func alertRoutingEvent(
    id: String?,
    agentScope: String,
    status: String = "done",
    timestamp: String = "2026-07-20T12:00:00Z"
) throws -> MewsEvent {
    var object: [String: Any] = [
        "source": "copilot",
        "status": status,
        "agent_scope": agentScope,
        "session_id": "routing-session",
        "timestamp": timestamp
    ]
    if let id {
        object["id"] = id
    }
    let data = try JSONSerialization.data(withJSONObject: object)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(MewsEvent.self, from: data)
}

private func alertRoutingExpect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw EventAlertRoutingTestFailure(message: message)
    }
}

private struct EventAlertRoutingTestFailure: Error {
    let message: String
}
