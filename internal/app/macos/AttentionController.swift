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
    static func unmatchedStopCandidates(
        transitions: [SessionStopTransition],
        attentionCandidates: [SessionAttentionCandidate]
    ) -> [SessionAttentionCandidate] {
        let attentionKeys = Set(attentionCandidates.map(\.key))
        return transitions.compactMap {
            attentionKeys.contains($0.key) ? nil : $0.candidate
        }
    }

    static func channel(
        status: SessionStatus,
        candidateIsRepresented: Bool,
        stopTransitionIsRepresented: Bool,
        stopTransitionWillPresent: Bool,
        physicalNotchAvailable: Bool
    ) -> EventAlertChannel {
        guard physicalNotchAvailable else {
            return .systemNotification
        }
        switch status {
        case .done, .failed:
            return stopTransitionIsRepresented &&
                stopTransitionWillPresent
                ? .notch
                : .systemNotification
        case .needsInput:
            return candidateIsRepresented
                ? .notch
                : .systemNotification
        case .running, .idle:
            return .systemNotification
        }
    }
}
