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

    func routeAttentionCandidates(
        _ candidates: [SessionAttentionCandidate],
        presentation: SessionPresentation,
        physicalNotchAvailable: Bool
    ) {
        for candidate in candidates {
            let represented = presentation.rows.contains { row in
                row.identity == candidate.identity &&
                    row.status == candidate.status
            }
            switch AttentionAlertRoutingPolicy.channel(
                status: candidate.status,
                candidateIsRepresented: represented,
                physicalNotchAvailable: physicalNotchAvailable
            ) {
            case .none:
                break
            case .notch:
                break
            case .systemNotification:
                notifications.send(for: candidate)
            }
        }
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
