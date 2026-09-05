import Foundation

struct SessionPresentationInput {
    let sessions: [CurrentSessionState]
    let attentionRecords: [AttentionRecord]
}

@MainActor
extension MewsApp {
    func finishReloadAfterEventReadFailure(now: Date) {
        let reload = EventReload(
            events: events,
            newEvents: [],
            recoveryEvents: events
        )
        finishReloadUsingPersistedSessions(
            reload,
            now: now,
            reconcilesAttention: true
        )
    }

    func finishReloadAfterSessionReconciliationFailure(
        snapshot: SessionControllerSnapshot,
        now: Date
    ) {
        let reload = EventReload(
            events: events,
            newEvents: [],
            recoveryEvents: events
        )
        finishReload(
            reload,
            sessionSnapshot: snapshot,
            now: now,
            reconcilesAttention: false
        )
    }

    private func finishReloadUsingPersistedSessions(
        _ reload: EventReload,
        now: Date,
        reconcilesAttention: Bool
    ) {
        configureSessionState()
        guard let sessionStateController else {
            finishReload(
                reload,
                sessionSnapshot: nil,
                now: now,
                reconcilesAttention: reconcilesAttention
            )
            return
        }
        sessionStateController.snapshot { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self, self.started else {
                    return
                }
                self.finishReload(
                    reload,
                    sessionSnapshot: snapshot,
                    now: now,
                    reconcilesAttention: reconcilesAttention
                )
            }
        }
    }

    func sessionPresentationInput(
        attentionUpdate: AttentionRuntimeUpdate?,
        sessionSnapshot: SessionControllerSnapshot?,
        reload: EventReload
    ) -> SessionPresentationInput {
        if let attentionUpdate {
            clearSessionPresentationError()
            return SessionPresentationInput(
                sessions: attentionUpdate.sessions,
                attentionRecords: attentionUpdate.reconciliation.state.persistedRecords
            )
        }
        if let sessionSnapshot {
            clearSessionPresentationError()
            return SessionPresentationInput(
                sessions: sessionSnapshot.sessions,
                attentionRecords: []
            )
        }
        let sessions = sessionPresentationSource.sessions(reconciling: reload)
        clearSessionPresentationError()
        return SessionPresentationInput(
            sessions: sessions,
            attentionRecords: []
        )
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
