import Foundation

struct SessionStateApplicationResult: Equatable {
    let changed: Bool
    let stopTransitionIdentifier: String?
}

extension SessionStateIndex {
    mutating func applyTrackingStopTransitions(
        _ events: [MewsEvent],
        now: Date,
        policy: SessionFreshnessPolicy = .standard,
        cliExecutablePath: String? = nil
    ) -> SessionStateApplicationResult {
        var changed = false
        var stopTransitionIdentifier: String?
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
                  let status = SessionStatus(rawValue: event.status),
                  status != previousStatus,
                  status == .done || status == .failed,
                  let identifier = MewsPresentationState(event: event)
                    .transitionIdentifier else {
                continue
            }
            stopTransitionIdentifier = "stop-event|\(identifier)"
        }
        return SessionStateApplicationResult(
            changed: changed,
            stopTransitionIdentifier: stopTransitionIdentifier
        )
    }
}
