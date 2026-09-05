import Foundation

enum SessionStatus: String, Codable, Equatable {
    case running
    case needsInput = "needs_input"
    case done
    case failed
    case idle
}

enum SessionPresence: Equatable {
    case open
    case closed
    case unknown
}

struct SessionIdentity: Codable, Hashable, Comparable {
    let source: String
    let sessionID: String

    init?(source: String, sessionID: String?) {
        guard let source = normalizedText(source),
              source.count <= 64,
              let sessionID = normalizedText(sessionID),
              sessionID.count <= 256 else {
            return nil
        }
        self.source = source
        self.sessionID = sessionID
    }

    static func < (left: SessionIdentity, right: SessionIdentity) -> Bool {
        if left.source != right.source {
            return left.source < right.source
        }
        return left.sessionID < right.sessionID
    }
}

struct SessionFreshnessPolicy: Equatable {
    static let standard = SessionFreshnessPolicy(
        activeLifetime: 24 * 60 * 60,
        settledLifetime: 30 * 60,
        futureTolerance: 5 * 60
    )

    let activeLifetime: TimeInterval
    let settledLifetime: TimeInterval
    let futureTolerance: TimeInterval

    func acceptsEvidence(evidenceAt: Date, now: Date) -> Bool {
        return now.timeIntervalSince(evidenceAt) >= -futureTolerance
    }

    func isFresh(status: SessionStatus, evidenceAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(evidenceAt)
        guard acceptsEvidence(evidenceAt: evidenceAt, now: now) else {
            return false
        }

        switch status {
        case .running, .needsInput:
            return age <= activeLifetime
        case .done, .failed, .idle:
            return age <= settledLifetime
        }
    }

    func currentStatus(status: SessionStatus, evidenceAt: Date, now: Date) -> SessionStatus {
        return isFresh(status: status, evidenceAt: evidenceAt, now: now) ? status : .idle
    }
}

struct CurrentSessionState: Equatable {
    let identity: SessionIdentity
    let status: SessionStatus
    let evidenceStatus: SessionStatus
    let statusChangedAt: Date
    let evidenceAt: Date
    let project: String?
    let hookEvent: String?
    let returnContext: CLIContextPayload?
    let isFresh: Bool
    let evidenceID: String
    let evidencePrecedence: Int
    let evidenceOrdinal: UInt64?
    let orderingKnown: Bool
    let equivalentEvidenceOverflow: Bool
    let dismissedEvidenceID: String?

    init(
        identity: SessionIdentity,
        status: SessionStatus,
        evidenceStatus: SessionStatus,
        statusChangedAt: Date,
        evidenceAt: Date,
        project: String?,
        hookEvent: String?,
        returnContext: CLIContextPayload?,
        isFresh: Bool,
        evidenceID: String = "",
        evidencePrecedence: Int = 0,
        evidenceOrdinal: UInt64? = nil,
        orderingKnown: Bool = false,
        equivalentEvidenceOverflow: Bool = false,
        dismissedEvidenceID: String? = nil
    ) {
        self.identity = identity
        self.status = status
        self.evidenceStatus = evidenceStatus
        self.statusChangedAt = statusChangedAt
        self.evidenceAt = evidenceAt
        self.project = project
        self.hookEvent = hookEvent
        self.returnContext = returnContext
        self.isFresh = isFresh
        self.evidenceID = evidenceID
        self.evidencePrecedence = evidencePrecedence
        self.evidenceOrdinal = evidenceOrdinal
        self.orderingKnown = orderingKnown
        self.equivalentEvidenceOverflow = equivalentEvidenceOverflow
        self.dismissedEvidenceID = dismissedEvidenceID
    }

    var source: String {
        identity.source
    }

    var sessionID: String {
        identity.sessionID
    }

    var isDismissed: Bool {
        dismissedEvidenceID == evidenceID
    }

    var presence: SessionPresence {
        let normalizedHook = normalizedText(hookEvent)?.lowercased()
        if normalizedHook == "sessionend" {
            return .closed
        }
        if normalizedHook != nil && (source == "claude-code" || source == "copilot") {
            return .open
        }
        if source == "codex",
           ["sessionstart", "userpromptsubmit", "stop"].contains(normalizedHook) {
            return .open
        }
        return .unknown
    }

    var presentationStatus: SessionStatus {
        guard presence == .open else {
            return status
        }
        return evidenceStatus == .idle ? .done : evidenceStatus
    }

    var isSubagentRunning: Bool {
        return presentationStatus == .running &&
            normalizedText(hookEvent)?.lowercased() == "subagentrunning"
    }
}
