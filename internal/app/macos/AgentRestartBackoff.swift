import Foundation

struct AgentRestartBackoff {
    static let baseRetryDelay: TimeInterval = 10
    static let maximumRetryDelay: TimeInterval = 5 * 60
    static let stabilityInterval: TimeInterval = 60

    private var nextAttempt: TimeInterval?
    private var startedAt: TimeInterval?
    private var failureCount = 0

    func shouldAttempt(at uptime: TimeInterval) -> Bool {
        guard let nextAttempt else {
            return true
        }
        return uptime >= nextAttempt
    }

    mutating func recordFailure(at uptime: TimeInterval) {
        if let startedAt,
           uptime - startedAt >= Self.stabilityInterval {
            failureCount = 0
        }
        self.startedAt = nil
        failureCount = min(failureCount + 1, 6)
        nextAttempt = uptime + retryDelay
    }

    mutating func recordStarted(at uptime: TimeInterval) {
        startedAt = uptime
        nextAttempt = nil
    }

    mutating func reset() {
        nextAttempt = nil
        startedAt = nil
        failureCount = 0
    }

    private var retryDelay: TimeInterval {
        let exponent = max(failureCount - 1, 0)
        let multiplier = 1 << exponent
        return min(
            Self.baseRetryDelay * TimeInterval(multiplier),
            Self.maximumRetryDelay
        )
    }
}

enum AgentProcessOwnership: Equatable {
    case none
    case child
    case external
}

enum AgentProcessAction: Equatable {
    case none
    case launch
}

struct AgentProcessCoordinator {
    private(set) var ownership = AgentProcessOwnership.none
    private var restartBackoff = AgentRestartBackoff()

    func shouldProbeSocket(
        childIsRunning: Bool,
        uptime: TimeInterval
    ) -> Bool {
        guard !childIsRunning else {
            return false
        }
        return ownership != .none || restartBackoff.shouldAttempt(at: uptime)
    }

    mutating func action(
        childIsRunning: Bool,
        socketResponsive: Bool,
        uptime: TimeInterval
    ) -> AgentProcessAction {
        if childIsRunning {
            ownership = .child
            return .none
        }
        if socketResponsive {
            ownership = .external
            restartBackoff.reset()
            return .none
        }
        if ownership == .external {
            restartBackoff.reset()
        } else if ownership == .child {
            restartBackoff.recordFailure(at: uptime)
        }
        ownership = .none
        return restartBackoff.shouldAttempt(at: uptime) ? .launch : .none
    }

    mutating func recordStarted(at uptime: TimeInterval) {
        ownership = .child
        restartBackoff.recordStarted(at: uptime)
    }

    mutating func recordLaunchFailure(at uptime: TimeInterval) {
        ownership = .none
        restartBackoff.recordFailure(at: uptime)
    }

    mutating func reset() {
        ownership = .none
        restartBackoff.reset()
    }
}
