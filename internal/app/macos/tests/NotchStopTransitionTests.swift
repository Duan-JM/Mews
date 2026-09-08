import Foundation

extension MewsAppModelTests {
    static func testExplicitNotchStopTransition() throws {
        var model = NotchInteractionModel(
            presentationState: MewsPresentationState(
                event: try stopTransitionEvent()
            )
        )
        let effects = model.send(
            .stoppedTransition(identifier: "parallel-stop")
        )
        guard case let .scheduleNotificationPeek(sequence, delay) = effects.first else {
            throw NotchStopTransitionTestFailure(
                message: "an explicit stop should schedule a pulse"
            )
        }
        try stopTransitionExpect(
            delay == NotchInteractionTiming.stoppedPulse,
            "the explicit stop pulse should last two seconds"
        )
        try stopTransitionExpect(
            model.state.visibility == .peek,
            "a stop in another session should pulse over a running aggregate"
        )
        _ = model.send(
            .presentationSynchronized(
                MewsPresentationState(event: try stopTransitionEvent(id: "resumed"))
            )
        )
        try stopTransitionExpect(
            model.state.visibility == .peek,
            "presentation updates should not end the two-second pulse early"
        )
        _ = model.send(.notificationPeekTimerFired(sequence: sequence))
        try stopTransitionExpect(
            model.state.visibility == .closed,
            "the pulse should restore the aggregate glow"
        )
    }

    private static func stopTransitionEvent(id: String? = nil) throws -> MewsEvent {
        var object: [String: Any] = [
            "source": "copilot",
            "status": "running",
            "agent_scope": "main",
            "timestamp": "2026-07-21T00:00:00Z"
        ]
        object["id"] = id
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MewsEvent.self, from: data)
    }

    private static func stopTransitionExpect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw NotchStopTransitionTestFailure(message: message)
        }
    }
}

private struct NotchStopTransitionTestFailure: Error {
    let message: String
}
