import Foundation

extension MewsAppModelTests {
    static func testAlertRoutingPolicy() throws {
        try testCurrentAlertRouting()
        try testFallbackAlertRouting()
        try testLegacyAlertRouting()
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
}

private func alertRoutingEvent(
    id: String?,
    agentScope: String
) throws -> MewsEvent {
    var object: [String: Any] = [
        "source": "copilot",
        "status": "done",
        "agent_scope": agentScope,
        "timestamp": "2026-07-20T12:00:00Z"
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
