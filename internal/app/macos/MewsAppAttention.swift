import Foundation

@MainActor
extension MewsApp {
    func configureAttention() {
        guard attentionController == nil else {
            return
        }
        do {
            attentionController = try AttentionController(
                storeDirectory: storeDirectoryURL
            )
            clearAttentionError()
        } catch {
            attentionController = nil
            recordAttentionError("Could not configure semantic attention: \(error)")
        }
    }

    func reconcileAttention(
        _ reload: EventReload,
        sessions: [CurrentSessionState]?
    ) -> AttentionRuntimeUpdate? {
        configureAttention()
        guard let attentionController, let sessions else {
            return nil
        }
        do {
            let update = try attentionController.reconcile(
                reload,
                sessions: sessions
            )
            clearAttentionError()
            return update
        } catch {
            recordAttentionError("Could not reconcile semantic attention: \(error)")
            return nil
        }
    }

    func acknowledgeAttention(
        identity: SessionIdentity?,
        notificationIdentifier: String? = nil
    ) {
        guard let identity, let attentionController else {
            return
        }
        do {
            let result = try attentionController.acknowledge(
                identity: identity,
                notificationIdentifier: notificationIdentifier
            )
            notifications.remove(identifiers: result.removalNotificationIdentifiers)
            clearAttentionError()
        } catch {
            recordAttentionError("Could not acknowledge semantic attention: \(error)")
        }
    }

    func currentSession(
        for event: MewsEvent?,
        in sessions: [CurrentSessionState]
    ) -> CurrentSessionState? {
        guard let event,
              let identity = SessionIdentity(
                  source: event.source,
                  sessionID: event.sessionID
              ) else {
            return nil
        }
        return sessions.first { $0.identity == identity }
    }

    private func recordAttentionError(_ message: String) {
        guard attentionErrorMessage != message else {
            return
        }
        attentionErrorMessage = message
        appendAppLog(message)
    }

    private func clearAttentionError() {
        guard attentionErrorMessage != nil else {
            return
        }
        attentionErrorMessage = nil
        appendAppLog("Semantic attention recovered")
    }
}
