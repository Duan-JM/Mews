import Foundation

struct AttentionRuntimeUpdate {
    let sessions: [CurrentSessionState]
    let reconciliation: AttentionReconciliation
}

final class AttentionController {
    private let sessions: SessionStateRepository
    private let attention: AttentionStateRepository

    init(
        storeDirectory: URL,
        clock: @escaping () -> Date = Date.init,
        cliExecutablePath: String? = nil
    ) throws {
        sessions = try SessionStateRepository(
            store: SessionStateStore(
                url: storeDirectory.appendingPathComponent("sessions.json")
            ),
            clock: clock,
            cliExecutablePath: cliExecutablePath
        )
        attention = try AttentionStateRepository(
            store: AttentionStateStore(
                url: storeDirectory.appendingPathComponent("attention.json")
            )
        )
    }

    func reconcile(_ reload: EventReload) throws -> AttentionRuntimeUpdate {
        _ = try sessions.apply(reload)
        let currentSessions = sessions.currentSessions()
        let candidates = currentSessions.compactMap { session in
            SessionAttentionCandidate(
                session: session,
                event: matchingEvent(for: session, in: reload.events)
            )
        }
        return AttentionRuntimeUpdate(
            sessions: currentSessions,
            reconciliation: try attention.reconcile(candidates: candidates)
        )
    }

    private func matchingEvent(
        for session: CurrentSessionState,
        in events: [MewsEvent]
    ) -> MewsEvent? {
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
