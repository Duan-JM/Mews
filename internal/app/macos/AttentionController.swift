import Foundation

struct AttentionRuntimeUpdate {
    let sessions: [CurrentSessionState]
    let reconciliation: AttentionReconciliation
}

final class AttentionController {
    private let attention: AttentionStateRepository

    init(storeDirectory: URL) throws {
        attention = try AttentionStateRepository(
            store: AttentionStateStore(
                url: storeDirectory.appendingPathComponent("attention.json")
            )
        )
    }

    func reconcile(
        _ reload: EventReload,
        sessions: [CurrentSessionState]
    ) throws -> AttentionRuntimeUpdate {
        let candidates = sessions.compactMap { session in
            SessionAttentionCandidate(
                session: session,
                event: matchingEvent(for: session, in: reload.events)
            )
        }
        return AttentionRuntimeUpdate(
            sessions: sessions,
            reconciliation: try attention.reconcile(candidates: candidates)
        )
    }

    private func matchingEvent(
        for session: CurrentSessionState,
        in events: [MewsEvent]
    ) -> MewsEvent? {
        if !session.evidenceID.isEmpty,
           let matchingEvidence = events.last(where: { event in
               event.id == session.evidenceID &&
                   event.source == session.identity.source &&
                   event.sessionID == session.identity.sessionID
           }) {
            return matchingEvidence
        }
        return events.last { event in
            event.affectsPrimaryStatus &&
                event.source == session.identity.source &&
                event.sessionID == session.identity.sessionID &&
                event.status == session.status.rawValue
        }
    }

    func acknowledge(
        identity: SessionIdentity,
        notificationIdentifier: String? = nil
    ) throws -> AttentionAcknowledgement {
        return try attention.acknowledge(
            identity: identity,
            notificationIdentifier: notificationIdentifier
        )
    }
}

struct AttentionAlertRoutingPolicy {
    static func channel(
        for candidate: SessionAttentionCandidate,
        notchSession: CurrentSessionState?,
        physicalNotchAvailable: Bool
    ) -> EventAlertChannel {
        guard physicalNotchAvailable,
              let notchSession,
              notchSession.identity == candidate.identity,
              notchSession.status == candidate.status,
              notchSession.statusChangedAt == candidate.key.statusChangedAt else {
            return .systemNotification
        }
        return .notch
    }
}
