import Foundation
import SwiftUI

extension SyntheticScreenshotCatalog {
    static func panelSessionFixtures() -> [SyntheticSessionFixture] {
        return [
            SyntheticSessionFixture(
                sourceID: "copilot",
                sourceLabel: "Copilot CLI",
                project: "ExampleApp",
                sessionID: "ask01",
                status: .needsInput,
                age: 0,
                actionable: true
            ),
            SyntheticSessionFixture(
                sourceID: "claude-code",
                sourceLabel: "Claude Code",
                project: "ExampleCLI",
                sessionID: "fail02",
                status: .failed,
                age: 1,
                actionable: false
            ),
            SyntheticSessionFixture(
                sourceID: "codex",
                sourceLabel: "Codex",
                project: "ExampleDocs",
                sessionID: "done03",
                status: .done,
                age: 2,
                actionable: true
            )
        ]
    }

    static func healthSessionFixtures() -> [SyntheticSessionFixture] {
        return [
            SyntheticSessionFixture(
                sourceID: "copilot",
                sourceLabel: "Copilot CLI",
                project: "ExampleKit",
                sessionID: "run04",
                status: .running,
                age: 3,
                actionable: true
            ),
            SyntheticSessionFixture(
                sourceID: "codex",
                sourceLabel: "Codex",
                project: "ExampleSite",
                sessionID: "idle05",
                status: .idle,
                age: 4,
                actionable: false
            )
        ]
    }

    @MainActor
    static func statusFixtures() throws -> [SyntheticStatusSnapshot] {
        let states = [
            SyntheticStatusCase(
                id: "idle",
                label: "IDLE",
                status: .idle,
                colorScheme: .light
            ),
            SyntheticStatusCase(
                id: "running",
                label: "RUN",
                status: .running,
                colorScheme: .light
            ),
            SyntheticStatusCase(
                id: "needs_input",
                label: "ASK",
                status: .needsInput,
                colorScheme: .light
            ),
            SyntheticStatusCase(
                id: "done",
                label: "DONE",
                status: .done,
                colorScheme: .dark
            ),
            SyntheticStatusCase(
                id: "failed",
                label: "FAIL",
                status: .failed,
                colorScheme: .dark
            )
        ]
        return try states.map { state in
            SyntheticStatusSnapshot(
                id: state.id,
                label: state.label,
                colorScheme: state.colorScheme,
                snapshot: NotchShellSnapshot(
                    visibility: .closed,
                    placementMode: .notch,
                    panelSize: CGSize(width: 116, height: 38),
                    anchorSize: CGSize(width: 44, height: 16),
                    presentationState: try presentationState(status: state.status),
                    content: .empty,
                    transitionStyle: .opacityOnly,
                    reduceTransparency: false,
                    increaseContrast: false
                )
            )
        }
    }

    @MainActor
    static func expandedSnapshot(
        sessions: [SyntheticSessionFixture],
        health: RuntimeHealthPresentation?,
        status: MewsPresentationStatus,
        now: Date,
        placementMode: OverlayPlacementMode
    ) throws -> NotchShellSnapshot {
        let rows = try sessions.map { try $0.row(now: now) }
        let presentation = SessionPresentation(rows: rows, health: health)
        let content = NotchPanelContent(
            presentation: presentation,
            events: [],
            currentEvent: nil
        )
        return NotchShellSnapshot(
            visibility: .expanded,
            placementMode: placementMode,
            panelSize: pointSize,
            anchorSize: CGSize(width: 52, height: 32),
            presentationState: try presentationState(status: status),
            content: content,
            transitionStyle: .opacityOnly,
            reduceTransparency: false,
            increaseContrast: false
        )
    }

    static func presentationState(
        status: MewsPresentationStatus
    ) throws -> MewsPresentationState {
        guard status != .idle else {
            return MewsPresentationState(event: nil)
        }
        let rawStatus = status.rawFixtureValue
        let data = try JSONSerialization.data(
            withJSONObject: [
                "id": "state-\(rawStatus)",
                "source": "synthetic",
                "status": rawStatus,
                "agent_scope": "main",
                "session_id": "state01",
                "timestamp": "2030-03-17T17:00:00Z"
            ],
            options: [.sortedKeys]
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return MewsPresentationState(event: try decoder.decode(MewsEvent.self, from: data))
    }

    static func validatePrivacy(
        sessions: [SyntheticSessionFixture],
        health: SyntheticHealthFixture
    ) throws {
        for session in sessions {
            try session.validate()
        }
        let forbiddenFragments = [
            "/users/",
            "/home/",
            "file://",
            "prompt",
            "scrollback",
            "terminal output",
            "terminal_output",
            "transcript"
        ]
        for value in fixtureText(sessions: sessions, health: health) {
            let lowercase = value.lowercased()
            guard !value.contains("\n"),
                  !forbiddenFragments.contains(where: lowercase.contains) else {
                throw SyntheticScreenshotError("unsafe fixture text: \(value)")
            }
        }
    }

    static func fixtureText(
        sessions: [SyntheticSessionFixture],
        health: SyntheticHealthFixture
    ) -> [String] {
        return sessions.flatMap(\.fixtureText) + health.fixtureText
    }
}

struct SyntheticStatusCase {
    let id: String
    let label: String
    let status: MewsPresentationStatus
    let colorScheme: ColorScheme
}

struct SyntheticSessionFixture {
    let sourceID: String
    let sourceLabel: String
    let project: String
    let sessionID: String
    let status: SessionStatus
    let age: TimeInterval
    let actionable: Bool

    var returnCommand: String? {
        return actionable ? "mw history --session '\(sessionID)'" : nil
    }

    var fixtureText: [String] {
        return [
            sourceID,
            sourceLabel,
            project,
            sessionID,
            returnCommand
        ].compactMap { $0 }
    }

    func validate() throws {
        let sessionRange = sessionID.range(
            of: "^[a-z][a-z0-9]{2,7}$",
            options: .regularExpression
        )
        guard sessionRange != nil,
              !project.contains("/"),
              returnCommand == nil ||
                returnCommand == "mw history --session '\(sessionID)'" else {
            throw SyntheticScreenshotError("invalid synthetic session fixture")
        }
    }

    func row(now: Date) throws -> SessionPresentationRow {
        guard let identity = SessionIdentity(source: sourceID, sessionID: sessionID) else {
            throw SyntheticScreenshotError("invalid synthetic session identity")
        }
        let context: CLIContextPayload?
        if let returnCommand {
            guard let payload = CLIContextPayload(
                returnCommand: returnCommand,
                workingDirectory: nil
            ) else {
                throw SyntheticScreenshotError("invalid synthetic return context")
            }
            context = payload
        } else {
            context = nil
        }
        return SessionPresentationRow(
            identity: identity,
            status: status,
            sourceLabel: sourceLabel,
            projectLabel: project,
            sessionLabel: sessionID,
            statusLabel: mewsStatusLabel(status.rawValue),
            statusCode: status.fixtureCode,
            returnContext: context,
            evidenceAt: now.addingTimeInterval(-age),
            priority: status.fixturePriority
        )
    }
}

struct SyntheticHealthFixture {
    let title: String
    let message: String
    let recovery: String

    var presentation: RuntimeHealthPresentation {
        return RuntimeHealthPresentation(
            state: .degraded,
            capabilityID: "event-delivery",
            title: title,
            message: message,
            recovery: recovery,
            additionalCount: 0
        )
    }

    var fixtureText: [String] {
        return [title, message, recovery]
    }
}

extension SessionStatus {
    var fixtureCode: String {
        switch self {
        case .idle:
            return "IDLE"
        case .running:
            return "RUN"
        case .needsInput:
            return "ASK"
        case .done:
            return "DONE"
        case .failed:
            return "FAIL"
        }
    }

    var fixturePriority: SessionPresentationPriority {
        switch self {
        case .needsInput:
            return .needsInput
        case .failed:
            return .failed
        case .done:
            return .unacknowledgedDone
        case .running:
            return .running
        case .idle:
            return .recent
        }
    }
}

extension MewsPresentationStatus {
    var rawFixtureValue: String {
        switch self {
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
}

extension ColorScheme {
    var fixtureName: String {
        return self == .dark ? "dark" : "light"
    }
}

extension OverlayPlacementMode {
    var fixtureName: String {
        switch self {
        case .notch:
            return "notch"
        case .topCenter:
            return "top_center"
        }
    }
}

struct SyntheticScreenshotError: LocalizedError {
    private let reason: String

    init(_ reason: String) {
        self.reason = reason
    }

    var errorDescription: String? {
        return reason
    }
}
