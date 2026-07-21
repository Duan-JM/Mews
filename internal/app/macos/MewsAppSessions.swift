import Foundation

struct SessionPresentationInput {
    let sessions: [CurrentSessionState]
    let attentionRecords: [AttentionRecord]
}

@MainActor
extension MewsApp {
    func sessionPresentationInput(
        attentionUpdate: AttentionRuntimeUpdate?,
        reload: EventReload
    ) -> SessionPresentationInput {
        if let attentionUpdate {
            clearSessionPresentationError()
            return SessionPresentationInput(
                sessions: attentionUpdate.sessions,
                attentionRecords: attentionUpdate.reconciliation.state.persistedRecords
            )
        }
        do {
            let sessions = try SessionPresentationSource(
                storeDirectory: storeDirectoryURL,
                cliExecutablePath: helperPath()
            ).sessions(reconciling: reload)
            clearSessionPresentationError()
            return SessionPresentationInput(
                sessions: sessions,
                attentionRecords: []
            )
        } catch {
            recordSessionPresentationError(
                "Could not recover session presentation: \(error)"
            )
            return SessionPresentationInput(
                sessions: [],
                attentionRecords: []
            )
        }
    }

    private func recordSessionPresentationError(_ message: String) {
        guard sessionPresentationErrorMessage != message else {
            return
        }
        sessionPresentationErrorMessage = message
        appendAppLog(message)
    }

    private func clearSessionPresentationError() {
        guard sessionPresentationErrorMessage != nil else {
            return
        }
        sessionPresentationErrorMessage = nil
        appendAppLog("Session presentation recovered")
    }
}
