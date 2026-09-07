import Foundation

enum SessionVisibilityPolicy {
    static func isDisplayable(
        session: CurrentSessionState,
        now: Date,
        policy: SessionFreshnessPolicy = .standard
    ) -> Bool {
        let age = now.timeIntervalSince(session.evidenceAt)
        guard age >= -policy.futureTolerance else {
            return false
        }
        switch session.presence {
        case .closed:
            return false
        case .open:
            return age <= policy.activeLifetime
        case .unknown:
            return session.isFresh && session.status != .idle
        }
    }
}
