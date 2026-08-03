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

    var source: String {
        identity.source
    }

    var sessionID: String {
        identity.sessionID
    }

    var presence: SessionPresence {
        let normalizedHook = normalizedText(hookEvent)?.lowercased()
        if normalizedHook == "sessionend" {
            return .closed
        }
        if normalizedHook != nil &&
            (source == "claude-code" || source == "copilot") {
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

struct SessionStateIndex: Equatable {
    private var records: [SessionIdentity: SessionStateRecord] = [:]

    var count: Int {
        records.count
    }

    init() {}

    init(restoring persistedRecords: [SessionStateRecord]) throws {
        for record in persistedRecords {
            guard SessionIdentity(
                source: record.identity.source,
                sessionID: record.identity.sessionID
            ) == record.identity,
                record.isValid,
                records[record.identity] == nil else {
                throw SessionStateValidationError.invalidRecord
            }
            records[record.identity] = record
        }
    }

    static func rebuilding(
        from events: [MewsEvent],
        now: Date,
        policy: SessionFreshnessPolicy = .standard,
        cliExecutablePath: String? = nil
    ) -> SessionStateIndex {
        var index = SessionStateIndex()
        _ = index.apply(
            events,
            now: now,
            policy: policy,
            cliExecutablePath: cliExecutablePath
        )
        return index
    }

    func currentSessions(
        now: Date,
        policy: SessionFreshnessPolicy = .standard,
        cliExecutablePath: String? = nil
    ) -> [CurrentSessionState] {
        return records.values
            .map {
                $0.current(
                    now: now,
                    policy: policy,
                    cliExecutablePath: cliExecutablePath
                )
            }
            .sorted {
                if $0.evidenceAt != $1.evidenceAt {
                    return $0.evidenceAt > $1.evidenceAt
                }
                return $0.identity < $1.identity
            }
    }

    @discardableResult
    mutating func apply(
        _ events: [MewsEvent],
        now: Date,
        policy: SessionFreshnessPolicy = .standard,
        cliExecutablePath: String? = nil
    ) -> Bool {
        var changed = false
        for event in events {
            changed = apply(
                event,
                now: now,
                policy: policy,
                cliExecutablePath: cliExecutablePath
            ) || changed
        }
        return changed
    }

    @discardableResult
    mutating func apply(
        _ event: MewsEvent,
        now: Date,
        policy: SessionFreshnessPolicy = .standard,
        cliExecutablePath: String? = nil
    ) -> Bool {
        guard event.affectsPrimaryStatus,
              let identity = SessionIdentity(source: event.source, sessionID: event.sessionID),
              let status = SessionStatus(rawValue: event.status),
              policy.acceptsEvidence(evidenceAt: event.timestamp, now: now) else {
            return false
        }

        let evidence = SessionEvidence(event: event, status: status)
        let current = records[identity]
        let replacesFutureRecord = current.map {
            !policy.acceptsEvidence(evidenceAt: $0.evidenceAt, now: now)
        } ?? false
        if let current, !replacesFutureRecord, !evidence.isNewer(than: current) {
            return false
        }

        records[identity] = SessionStateRecord(
            replacing: replacesFutureRecord ? nil : current,
            identity: identity,
            status: status,
            evidence: evidence,
            project: normalizedText(event.project),
            hookEvent: normalizedText(event.hookEvent),
            context: SessionReturnContext(
                payload: event.cliContext(cliExecutablePath: cliExecutablePath)
            )
        )
        return true
    }

    var persistedRecords: [SessionStateRecord] {
        return records.values.sorted { $0.identity < $1.identity }
    }
}

enum SessionStateValidationError: Error {
    case invalidRecord
}

struct SessionStateRecord: Codable, Equatable {
    let identity: SessionIdentity
    let status: SessionStatus
    let statusChangedAt: Date
    let evidenceAt: Date
    let project: String?
    let hookEvent: String?
    let context: SessionReturnContext?
    let evidencePrecedence: Int
    let evidenceID: String

    var isValid: Bool {
        guard statusChangedAt <= evidenceAt,
              normalizedText(evidenceID) == evidenceID,
              evidenceID.count <= 1024,
              evidencePrecedence == SessionEvidence.precedence(
                  source: identity.source,
                  status: status,
                  hookEvent: hookEvent
              ) else {
            return false
        }
        if let project, normalizedText(project) != project || project.count > 256 {
            return false
        }
        if let hookEvent, normalizedText(hookEvent) != hookEvent || hookEvent.count > 128 {
            return false
        }
        return true
    }

    init(
        replacing existing: SessionStateRecord?,
        identity: SessionIdentity,
        status: SessionStatus,
        evidence: SessionEvidence,
        project: String?,
        hookEvent: String?,
        context: SessionReturnContext?
    ) {
        self.identity = identity
        self.status = status
        if existing?.status == status, let priorChange = existing?.statusChangedAt {
            statusChangedAt = priorChange
        } else {
            statusChangedAt = evidence.timestamp
        }
        evidenceAt = evidence.timestamp
        self.project = project ?? existing?.project
        self.hookEvent = hookEvent
        self.context = SessionReturnContext.merging(
            prior: existing?.context,
            newer: context
        )
        evidencePrecedence = evidence.precedence
        evidenceID = evidence.id
    }

    func current(
        now: Date,
        policy: SessionFreshnessPolicy,
        cliExecutablePath: String?
    ) -> CurrentSessionState {
        let fresh = policy.isFresh(status: status, evidenceAt: evidenceAt, now: now)
        return CurrentSessionState(
            identity: identity,
            status: policy.currentStatus(status: status, evidenceAt: evidenceAt, now: now),
            evidenceStatus: status,
            statusChangedAt: statusChangedAt,
            evidenceAt: evidenceAt,
            project: project,
            hookEvent: hookEvent,
            returnContext: SessionReturnContext.payload(
                metadata: context,
                sessionID: identity.sessionID,
                cliExecutablePath: cliExecutablePath
            ),
            isFresh: fresh
        )
    }
}

struct SessionEvidence {
    let timestamp: Date
    let precedence: Int
    let id: String

    init(event: MewsEvent, status: SessionStatus) {
        timestamp = event.timestamp
        precedence = Self.precedence(
            source: event.source,
            status: status,
            hookEvent: event.hookEvent
        )
        id = normalizedText(event.id) ?? Self.legacyID(event: event)
    }

    func isNewer(than record: SessionStateRecord) -> Bool {
        if id == record.evidenceID {
            return false
        }
        if timestamp != record.evidenceAt {
            return timestamp > record.evidenceAt
        }
        if precedence != record.evidencePrecedence {
            return precedence > record.evidencePrecedence
        }
        return id > record.evidenceID
    }

    static func precedence(
        source: String,
        status: SessionStatus,
        hookEvent: String?
    ) -> Int {
        let hook = normalizedText(hookEvent)?.lowercased()
        if hook == "sessionend" {
            return 500
        }
        if source == "runner", status == .done || status == .failed {
            return 400
        }
        switch status {
        case .idle:
            return 350
        case .done, .failed:
            return 300
        case .needsInput:
            return 200
        case .running:
            return 100
        }
    }

    private static func legacyID(event: MewsEvent) -> String {
        let timestamp = event.timestamp.timeIntervalSinceReferenceDate.bitPattern
        return [
            event.source,
            event.status,
            normalizedText(event.hookEvent) ?? "",
            normalizedText(event.agentScope) ?? "",
            event.recoverable == true ? "recoverable" : "primary",
            normalizedText(event.sessionID) ?? "",
            normalizedText(event.project) ?? "",
            String(timestamp)
        ].joined(separator: "\u{1F}")
    }
}
