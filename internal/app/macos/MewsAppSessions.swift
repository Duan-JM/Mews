import Foundation

struct SessionPresentationInput {
    let sessions: [CurrentSessionState]
    let attentionRecords: [AttentionRecord]
    let revision: UInt64?
}

@MainActor
extension MewsApp {
    func dismissSession(
        _ request: SessionDismissalRequest,
        completion: @escaping (Result<SessionDismissalResponse, Error>) -> Void
    ) {
        configureSessionState()
        guard let sessionStateController else {
            completion(.failure(MewsSessionDismissalError.controllerUnavailable))
            return
        }
        sessionStateController.dismiss(request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.started else {
                    return
                }
                completion(result)
                if case .success = result {
                    self.reloadEvents()
                }
            }
        }
    }

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

    private enum MewsSessionDismissalError: Error {
        case controllerUnavailable
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
                attentionRecords: attentionUpdate.reconciliation.state.persistedRecords,
                revision: sessionSnapshot?.revision
            )
        }
        if let sessionSnapshot {
            clearSessionPresentationError()
            return SessionPresentationInput(
                sessions: sessionSnapshot.sessions,
                attentionRecords: [],
                revision: sessionSnapshot.revision
            )
        }
        let sessions = sessionPresentationSource.sessions(reconciling: reload)
        clearSessionPresentationError()
        return SessionPresentationInput(
            sessions: sessions,
            attentionRecords: [],
            revision: nil
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
