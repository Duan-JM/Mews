import Foundation
import SwiftUI

struct SyntheticStatusSnapshot: Identifiable {
    let id: String
    let label: String
    let colorScheme: ColorScheme
    let snapshot: NotchShellSnapshot
}

struct SyntheticPanelSnapshot {
    let colorScheme: ColorScheme
    let snapshot: NotchShellSnapshot
}

struct SyntheticScreenshotCatalog {
    static let pointSize = CGSize(width: 420, height: 220)
    static let pixelWidth = 840
    static let pixelHeight = 440
    static let statusFileName = "mews-status-states.png"
    static let sessionsFileName = "mews-multi-session.png"
    static let healthFileName = "mews-degraded-health.png"

    let statusSnapshots: [SyntheticStatusSnapshot]
    let sessionsPanel: SyntheticPanelSnapshot
    let healthPanel: SyntheticPanelSnapshot
    let fixtureText: [String]
    let sessionIDs: [String]

    var outputFileNames: [String] {
        return [
            Self.statusFileName,
            Self.sessionsFileName,
            Self.healthFileName
        ]
    }

    var stateNames: [String] {
        return statusSnapshots.map(\.id)
    }

    var appearanceNames: [String] {
        let panelSchemes = [
            sessionsPanel.colorScheme,
            healthPanel.colorScheme
        ]
        return Array(
            Set(statusSnapshots.map(\.colorScheme.fixtureName) +
                panelSchemes.map(\.fixtureName))
        ).sorted()
    }

    var placementNames: [String] {
        let panelModes = [
            sessionsPanel.snapshot.placementMode,
            healthPanel.snapshot.placementMode
        ]
        return Array(
            Set(statusSnapshots.map(\.snapshot.placementMode.fixtureName) +
                panelModes.map(\.fixtureName))
        ).sorted()
    }

    @MainActor
    static func make() throws -> SyntheticScreenshotCatalog {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let panelSessions = panelSessionFixtures()
        let healthSessions = healthSessionFixtures()
        let health = SyntheticHealthFixture(
            title: "Event delivery",
            message: "Local agent reconnecting",
            recovery: "mw doctor"
        )
        let allSessions = panelSessions + healthSessions
        try validatePrivacy(sessions: allSessions, health: health)

        return SyntheticScreenshotCatalog(
            statusSnapshots: try statusFixtures(),
            sessionsPanel: SyntheticPanelSnapshot(
                colorScheme: .light,
                snapshot: try expandedSnapshot(
                    sessions: panelSessions,
                    health: nil,
                    status: .needsInput,
                    now: now,
                    placementMode: .topCenter
                )
            ),
            healthPanel: SyntheticPanelSnapshot(
                colorScheme: .dark,
                snapshot: try expandedSnapshot(
                    sessions: healthSessions,
                    health: health.presentation,
                    status: .running,
                    now: now,
                    placementMode: .topCenter
                )
            ),
            fixtureText: fixtureText(sessions: allSessions, health: health),
            sessionIDs: allSessions.map(\.sessionID)
        )
    }

}
