import Foundation

extension MewsAppModelTests {
    static func testNotchGlowPresentation() throws {
        try testIdleGlow()
        try testAggregateGlow()
        try testEmptySessionPresentationGlow()
        try testAttentionGlow()
        try testTransientStopGlow()
    }

    private static func testEmptySessionPresentationGlow() throws {
        let hidden = NotchGlowPresentation.resolved(
            snapshot: try glowSnapshot(
                status: .done,
                aggregateStatuses: []
            )
        )
        try glowExpect(
            hidden == NotchGlowPresentation(signal: .hidden, pulses: false),
            "an empty session presentation should not retain a legacy red glow"
        )
    }

    private static func testIdleGlow() throws {
        let idle = NotchGlowPresentation.resolved(
            snapshot: try glowSnapshot(status: .idle)
        )
        try glowExpect(
            idle == NotchGlowPresentation(signal: .hidden, pulses: false),
            "idle should leave the physical notch visually quiet"
        )
    }

    private static func testAggregateGlow() throws {
        let running = NotchGlowPresentation.resolved(
            snapshot: try glowSnapshot(
                status: .done,
                rows: [
                    try glowRow(id: "stopped", status: .done),
                    try glowRow(id: "running", status: .running)
                ]
            )
        )
        try glowExpect(
            running == NotchGlowPresentation(signal: .running, pulses: false),
            "any running session should restore the steady green glow"
        )

        let stopped = NotchGlowPresentation.resolved(
            snapshot: try glowSnapshot(
                status: .done,
                rows: [
                    try glowRow(id: "done", status: .done),
                    try glowRow(id: "failed", status: .failed)
                ]
            )
        )
        try glowExpect(
            stopped == NotchGlowPresentation(signal: .stopped, pulses: false),
            "an all-stopped session set should retain a steady red glow"
        )
    }

    private static func testAttentionGlow() throws {
        let attention = NotchGlowPresentation.resolved(
            snapshot: try glowSnapshot(
                status: .running,
                rows: [
                    try glowRow(id: "running", status: .running),
                    try glowRow(id: "input", status: .needsInput)
                ]
            )
        )
        try glowExpect(
            attention == NotchGlowPresentation(signal: .attention, pulses: true),
            "needs-input should keep a red breathing signal until resolved"
        )
    }

    private static func testTransientStopGlow() throws {
        let transientStop = NotchGlowPresentation.resolved(
            snapshot: try glowSnapshot(
                status: .done,
                visibility: .peek,
                rows: [try glowRow(id: "running", status: .running)]
            )
        )
        try glowExpect(
            transientStop == NotchGlowPresentation(signal: .stopped, pulses: true),
            "a new stop should temporarily override the aggregate running glow"
        )
    }

    private static func glowSnapshot(
        status: MewsPresentationStatus,
        visibility: NotchVisibility = .closed,
        rows: [SessionPresentationRow] = [],
        aggregateStatuses: [SessionStatus]? = nil
    ) throws -> NotchShellSnapshot {
        let presentation = SessionPresentation(
            rows: rows,
            aggregateStatuses: aggregateStatuses,
            health: nil
        )
        return NotchShellSnapshot(
            visibility: visibility,
            placementMode: .notch,
            panelSize: CGSize(width: 420, height: 220),
            anchorSize: CGSize(width: 52, height: 32),
            presentationState: try glowPresentationState(status: status),
            content: NotchPanelContent(
                presentation: presentation,
                events: [],
                currentEvent: nil
            ),
            transitionStyle: .spatial,
            reduceTransparency: false,
            increaseContrast: false
        )
    }

    private static func glowRow(
        id: String,
        status: SessionStatus
    ) throws -> SessionPresentationRow {
        guard let identity = SessionIdentity(source: "test", sessionID: id) else {
            throw NotchGlowViewTestFailure(message: "invalid glow fixture identity")
        }
        return SessionPresentationRow(
            identity: identity,
            status: status,
            sourceLabel: "Test",
            projectLabel: nil,
            sessionLabel: id,
            statusLabel: status.sessionPresentationLabel,
            statusCode: status.sessionPresentationCode,
            returnContext: nil,
            evidenceAt: Date(timeIntervalSince1970: 1_900_000_000),
            priority: .recent
        )
    }

    private static func glowPresentationState(
        status: MewsPresentationStatus
    ) throws -> MewsPresentationState {
        guard status != .idle else {
            return MewsPresentationState(event: nil)
        }
        let rawStatus = glowRawStatus(status)
        let data = try JSONSerialization.data(
            withJSONObject: [
                "id": "glow-\(rawStatus)",
                "source": "test",
                "status": rawStatus,
                "agent_scope": "main",
                "session_id": "glow",
                "timestamp": "2030-03-17T17:00:00Z"
            ]
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return MewsPresentationState(
            event: try decoder.decode(MewsEvent.self, from: data)
        )
    }

    private static func glowRawStatus(
        _ status: MewsPresentationStatus
    ) -> String {
        switch status {
        case .idle:
            return "idle"
        case .running:
            return "running"
        case .needsInput:
            return "needs_input"
        case .done:
            return "done"
        case .failed:
            return "failed"
        }
    }

    private static func glowExpect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw NotchGlowViewTestFailure(message: message)
        }
    }
}

private struct NotchGlowViewTestFailure: Error {
    let message: String
}
