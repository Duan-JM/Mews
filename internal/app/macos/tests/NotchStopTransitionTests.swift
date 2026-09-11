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
        _ = model.send(.notchClick(isPanelControl: false))
        try stopTransitionExpect(
            model.state.visibility == .expanded &&
                model.state.stopPulseActive,
            "expanding during a stop pulse should preserve the red effect"
        )
        _ = model.send(
            .presentationSynchronized(
                MewsPresentationState(event: try stopTransitionEvent(id: "resumed"))
            )
        )
        try stopTransitionExpect(
            model.state.visibility == .expanded &&
                model.state.stopPulseActive,
            "presentation updates should not end the two-second pulse early"
        )
        _ = model.send(.notificationPeekTimerFired(sequence: sequence))
        try stopTransitionExpect(
            model.state.visibility == .expanded &&
                !model.state.stopPulseActive,
            "the pulse should expire without collapsing the expanded panel"
        )
        try assertExpandedStopStartsPulse(model: &model)
        try assertExpandedStatusStartsPulse()
    }

    private static func assertExpandedStopStartsPulse(
        model: inout NotchInteractionModel
    ) throws {
        let expandedEffects = model.send(
            .stoppedTransition(identifier: "expanded-stop")
        )
        try stopTransitionExpect(
            model.state.visibility == .expanded &&
                model.state.stopPulseActive &&
                expandedEffects.count == 1,
            "a stop received while expanded should pulse on the panel edge"
        )
    }

    private static func assertExpandedStatusStartsPulse() throws {
        var model = NotchInteractionModel(
            presentationState: MewsPresentationState(event: nil)
        )
        _ = model.send(.logoPrimaryClick)
        let done = MewsPresentationState(
            event: try stopTransitionEvent(
                id: "expanded-status-stop",
                status: "done"
            )
        )
        let effects = model.send(.presentationChanged(done))
        try stopTransitionExpect(
            model.state.visibility == .expanded &&
                model.state.stopPulseActive &&
                effects.count == 1,
            "a completion received while expanded should start an edge pulse"
        )
    }

    private static func stopTransitionEvent(
        id: String? = nil,
        status: String = "running"
    ) throws -> MewsEvent {
        var object: [String: Any] = [
            "source": "copilot",
            "status": status,
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
