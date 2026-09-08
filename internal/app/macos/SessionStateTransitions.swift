import Foundation

struct SessionStateApplicationResult: Equatable {
    let changed: Bool
    let stopTransitions: [SessionStopTransition]

    var stopTransitionIdentifier: String? {
        return stopTransitions.last?.identifier
    }
}

struct SessionStopTransition: Equatable {
    let candidate: SessionAttentionCandidate
    let identifier: String

    var key: AttentionKey {
        return candidate.key
    }

    func isRepresentedOrSuperseded(
        by sessions: [CurrentSessionState]
    ) -> Bool {
        guard let session = sessions.first(where: {
            $0.identity == candidate.identity
        }) else {
            return false
        }
        return session.status != candidate.status ||
            session.statusChangedAt == candidate.key.statusChangedAt
    }
}

extension SessionStateIndex {
    mutating func applyTrackingStopTransitions(
        _ events: [MewsEvent],
        now: Date,
        policy: SessionFreshnessPolicy = .standard,
        cliExecutablePath: String? = nil
    ) -> SessionStateApplicationResult {
        var changed = false
        var stopTransitions: [SessionStopTransition] = []
        for event in events {
            let identity = SessionIdentity(
                source: event.source,
                sessionID: event.sessionID
            )
            let previousStatus = identity.flatMap {
                evidenceStatus(for: $0)
            }
            let accepted = apply(
                event,
                now: now,
                policy: policy,
                cliExecutablePath: cliExecutablePath
            )
            changed = accepted || changed
            guard accepted,
                  let transition = stopTransition(
                      for: event,
                      prior: (identity, previousStatus),
                      now: now,
                      policy: policy,
                      cliExecutablePath: cliExecutablePath
                  ) else {
                continue
            }
            stopTransitions.append(transition)
        }
        return SessionStateApplicationResult(
            changed: changed,
            stopTransitions: stopTransitions
        )
    }

    private func stopTransition(
        for event: MewsEvent,
        prior: (identity: SessionIdentity?, status: SessionStatus?),
        now: Date,
        policy: SessionFreshnessPolicy,
        cliExecutablePath: String?
    ) -> SessionStopTransition? {
        guard let identity = prior.identity,
              let status = SessionStatus(rawValue: event.status),
              policy.isFresh(status: status, evidenceAt: event.timestamp, now: now),
              status != prior.status,
              status == .done || status == .failed,
              let eventIdentifier = MewsPresentationState(event: event)
                .transitionIdentifier,
              let session = currentSessions(
                  now: now,
                  policy: policy,
                  cliExecutablePath: cliExecutablePath
              ).first(where: { $0.identity == identity }),
              let candidate = SessionAttentionCandidate(session: session, event: event) else {
            return nil
        }
        let timestamp = String(
            event.timestamp.timeIntervalSinceReferenceDate.bitPattern,
            radix: 16
        )
        let identifier = [
            "stop-event",
            identity.source,
            identity.sessionID,
            status.rawValue,
            timestamp,
            eventIdentifier
        ].joined(separator: "|")
        return SessionStopTransition(candidate: candidate, identifier: identifier)
    }
}
