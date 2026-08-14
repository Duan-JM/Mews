import Foundation

enum AttentionDisposition: String, Codable, Equatable {
    case delivered
    case acknowledged
    case resolved
}

struct AttentionKey: Codable, Hashable, Comparable {
    let identity: SessionIdentity
    let status: SessionStatus
    let statusChangedAt: Date

    init?(identity: SessionIdentity, status: SessionStatus, statusChangedAt: Date) {
        guard status.isAttentionStatus,
              statusChangedAt.timeIntervalSinceReferenceDate.isFinite else {
            return nil
        }
        self.identity = identity
        self.status = status
        self.statusChangedAt = statusChangedAt
    }

    var notificationIdentifier: String {
        let timestamp = String(statusChangedAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
        let components = [
            identity.source,
            identity.sessionID,
            status.rawValue,
            timestamp
        ]
        let encoded = components.map(stableIdentifierComponent).joined(separator: ".")
        return "dev.mews.attention.v1.\(encoded)"
    }

    static func < (left: AttentionKey, right: AttentionKey) -> Bool {
        if left.statusChangedAt != right.statusChangedAt {
            return left.statusChangedAt < right.statusChangedAt
        }
        if left.identity != right.identity {
            return left.identity < right.identity
        }
        return left.status.rawValue < right.status.rawValue
    }
}

struct SessionAttentionCandidate: Equatable {
    let key: AttentionKey
    let project: String?
    let hookEvent: String?
    let returnContext: CLIContextPayload?
    let taskTitle: String?
    let message: String?

    init?(session: CurrentSessionState, event: MewsEvent? = nil) {
        guard session.isFresh,
              let key = AttentionKey(
                  identity: session.identity,
                  status: session.status,
                  statusChangedAt: session.statusChangedAt
              ) else {
            return nil
        }
        self.key = key
        project = session.project
        hookEvent = session.hookEvent
        returnContext = session.returnContext
        taskTitle = event?.taskTitle
        message = event?.message
    }

    var identity: SessionIdentity {
        key.identity
    }

    var status: SessionStatus {
        key.status
    }

    var notificationIdentifier: String {
        key.notificationIdentifier
    }

    var notificationTitle: String {
        mewsNotificationTitle(source: identity.source, status: status.rawValue)
    }

    var notificationSubtitle: String {
        mewsNotificationSubtitle(project: project, sessionID: identity.sessionID)
    }

    var notificationBody: String {
        mewsNotificationBody(
            status: status.rawValue,
            hookEvent: hookEvent,
            taskTitle: taskTitle,
            message: message
        )
    }

    var notificationUserInfo: [String: String] {
        var info = returnContext?.userInfo ?? [:]
        info["source"] = identity.source
        info["session_id"] = identity.sessionID
        info["attention_id"] = notificationIdentifier
        return info
    }
}

struct AttentionRecord: Codable, Equatable {
    let identity: SessionIdentity
    let key: AttentionKey
    let disposition: AttentionDisposition

    var isValid: Bool {
        identity == key.identity &&
            AttentionKey(
                identity: key.identity,
                status: key.status,
                statusChangedAt: key.statusChangedAt
            ) == key
    }
}

struct AttentionState: Equatable {
    fileprivate var records: [SessionIdentity: AttentionRecord] = [:]

    init() {}

    init(restoring persistedRecords: [AttentionRecord]) throws {
        for record in persistedRecords {
            guard record.isValid, records[record.identity] == nil else {
                throw AttentionStateValidationError.invalidRecord
            }
            records[record.identity] = record
        }
    }

    var persistedRecords: [AttentionRecord] {
        records.values.sorted { $0.identity < $1.identity }
    }

    var activeCount: Int {
        records.values.filter { $0.disposition == .delivered }.count
    }
}

enum AttentionStateValidationError: Error {
    case invalidRecord
}

struct ResolvedAttention: Equatable {
    let key: AttentionKey

    var notificationIdentifier: String {
        key.notificationIdentifier
    }
}

struct AttentionReconciliation: Equatable {
    let newlyAlertable: [SessionAttentionCandidate]
    let resolved: [ResolvedAttention]
    let activeCount: Int
    let state: AttentionState

    var newNotificationIdentifiers: [String] {
        newlyAlertable.map(\.notificationIdentifier)
    }

    var resolvedNotificationIdentifiers: [String] {
        resolved.map(\.notificationIdentifier)
    }
}

struct AttentionAcknowledgement: Equatable {
    let acknowledged: AttentionKey?
    let activeCount: Int
    let state: AttentionState

    var removalNotificationIdentifiers: [String] {
        acknowledged.map { [$0.notificationIdentifier] } ?? []
    }
}

struct AttentionReconciler {
    func reconcile(
        candidates: [SessionAttentionCandidate],
        state: AttentionState
    ) -> AttentionReconciliation {
        let current = newestCandidatesByIdentity(candidates)
        var next = state
        var newlyAlertable: [SessionAttentionCandidate] = []
        var resolved: [ResolvedAttention] = []

        for record in state.records.values where current[record.identity] == nil {
            if record.disposition == .delivered {
                resolved.append(ResolvedAttention(key: record.key))
            }
            next.records[record.identity] = AttentionRecord(
                identity: record.identity,
                key: record.key,
                disposition: .resolved
            )
        }

        for candidate in current.values {
            let prior = state.records[candidate.identity]
            if prior?.key == candidate.key {
                continue
            }
            if let prior, candidate.key.statusChangedAt < prior.key.statusChangedAt {
                continue
            }
            if let prior, prior.disposition == .delivered {
                resolved.append(ResolvedAttention(key: prior.key))
            }
            next.records[candidate.identity] = AttentionRecord(
                identity: candidate.identity,
                key: candidate.key,
                disposition: .delivered
            )
            newlyAlertable.append(candidate)
        }

        return AttentionReconciliation(
            newlyAlertable: newlyAlertable.sorted { $0.key < $1.key },
            resolved: resolved.sorted { $0.key < $1.key },
            activeCount: next.activeCount,
            state: next
        )
    }

    func acknowledge(
        identity: SessionIdentity,
        notificationIdentifier: String? = nil,
        state: AttentionState
    ) -> AttentionAcknowledgement {
        guard let record = state.records[identity],
              record.disposition == .delivered,
              notificationIdentifier == nil ||
                notificationIdentifier == record.key.notificationIdentifier else {
            return AttentionAcknowledgement(
                acknowledged: nil,
                activeCount: state.activeCount,
                state: state
            )
        }

        var next = state
        next.records[identity] = AttentionRecord(
            identity: identity,
            key: record.key,
            disposition: .acknowledged
        )
        return AttentionAcknowledgement(
            acknowledged: record.key,
            activeCount: next.activeCount,
            state: next
        )
    }

    private func newestCandidatesByIdentity(
        _ candidates: [SessionAttentionCandidate]
    ) -> [SessionIdentity: SessionAttentionCandidate] {
        return candidates.reduce(into: [:]) { result, candidate in
            if let existing = result[candidate.identity], existing.key > candidate.key {
                return
            }
            result[candidate.identity] = candidate
        }
    }
}

extension SessionStatus {
    var isAttentionStatus: Bool {
        switch self {
        case .needsInput, .done, .failed:
            return true
        case .running, .idle:
            return false
        }
    }
}

private func stableIdentifierComponent(_ value: String) -> String {
    return Data(value.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
