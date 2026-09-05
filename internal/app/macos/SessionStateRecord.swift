import Foundation

enum SessionStateValidationError: Error {
    case invalidRecord
    case invalidOrdering
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
    var evidenceOrdinal: UInt64?
    var equivalentEvidenceIDs: [String]?
    var equivalentEvidenceOverflow: Bool

    enum CodingKeys: String, CodingKey {
        case identity
        case status
        case statusChangedAt
        case evidenceAt
        case project
        case hookEvent
        case context
        case evidencePrecedence
        case evidenceID
        case evidenceOrdinal
        case equivalentEvidenceIDs
        case equivalentEvidenceOverflow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = try container.decode(SessionIdentity.self, forKey: .identity)
        status = try container.decode(SessionStatus.self, forKey: .status)
        statusChangedAt = try container.decode(Date.self, forKey: .statusChangedAt)
        evidenceAt = try container.decode(Date.self, forKey: .evidenceAt)
        project = try container.decodeIfPresent(String.self, forKey: .project)
        hookEvent = try container.decodeIfPresent(String.self, forKey: .hookEvent)
        context = try container.decodeIfPresent(SessionReturnContext.self, forKey: .context)
        evidencePrecedence = try container.decode(Int.self, forKey: .evidencePrecedence)
        evidenceID = try container.decode(String.self, forKey: .evidenceID)
        evidenceOrdinal = try container.decodeIfPresent(UInt64.self, forKey: .evidenceOrdinal)
        equivalentEvidenceIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .equivalentEvidenceIDs
        )
        equivalentEvidenceOverflow = try container.decodeIfPresent(
            Bool.self,
            forKey: .equivalentEvidenceOverflow
        ) ?? false
    }

    init(
        replacing existing: SessionStateRecord?,
        identity: SessionIdentity,
        status: SessionStatus,
        evidence: SessionEvidence,
        project: String?,
        hookEvent: String?,
        context: SessionReturnContext?,
        evidenceOrdinal: UInt64,
        equivalentEvidenceIDs: [String],
        equivalentEvidenceOverflow: Bool
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
        self.evidenceOrdinal = evidenceOrdinal
        self.equivalentEvidenceIDs = equivalentEvidenceIDs
        self.equivalentEvidenceOverflow = equivalentEvidenceOverflow
    }

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
        guard orderingKnown else {
            return evidenceOrdinal == nil &&
                equivalentEvidenceIDs == nil &&
                !equivalentEvidenceOverflow
        }
        guard let equivalentEvidenceIDs,
              equivalentEvidenceIDs.count <= SessionEvidence.maximumEquivalentIDs,
              !equivalentEvidenceIDs.isEmpty,
              Set(equivalentEvidenceIDs).count == equivalentEvidenceIDs.count,
              equivalentEvidenceIDs.last == evidenceID,
              equivalentEvidenceIDs.allSatisfy({ normalizedText($0) == $0 }),
              evidenceOrdinal ?? 0 > 0 else {
            return false
        }
        return true
    }

    var orderingKnown: Bool {
        evidenceOrdinal != nil && equivalentEvidenceIDs != nil
    }

    var orderingKey: SessionEvidenceOrderingKey {
        SessionEvidenceOrderingKey(
            timestamp: evidenceAt,
            precedence: evidencePrecedence
        )
    }

    func withUnknownOrdering() -> SessionStateRecord {
        var copy = self
        copy.evidenceOrdinal = nil
        copy.equivalentEvidenceIDs = nil
        copy.equivalentEvidenceOverflow = false
        return copy
    }

    func attachingOrdering(from projected: SessionStateRecord) -> SessionStateRecord {
        var copy = self
        copy.evidenceOrdinal = projected.evidenceOrdinal
        copy.equivalentEvidenceIDs = projected.equivalentEvidenceIDs
        copy.equivalentEvidenceOverflow = projected.equivalentEvidenceOverflow
        return copy
    }

    func mergingEquivalentEvidence(from projected: SessionStateRecord) -> SessionStateRecord {
        guard evidenceID == projected.evidenceID else {
            return self
        }
        let prior = equivalentEvidenceIDs ?? [evidenceID]
        let replayed = projected.equivalentEvidenceIDs ?? [evidenceID]
        var seen = Set<String>()
        let predecessors = (prior.dropLast() + replayed.dropLast()).filter {
            seen.insert($0).inserted
        }
        let capacity = SessionEvidence.maximumEquivalentIDs - 1
        var copy = self
        copy.equivalentEvidenceIDs = Array(predecessors.suffix(capacity)) + [evidenceID]
        copy.equivalentEvidenceOverflow =
            equivalentEvidenceOverflow ||
            projected.equivalentEvidenceOverflow ||
            predecessors.count > capacity
        return copy
    }

    func mergingPersistedMetadata(from prior: SessionStateRecord) -> SessionStateRecord {
        return SessionStateRecord(
            identity: identity,
            status: status,
            statusChangedAt: prior.status == status ? prior.statusChangedAt : statusChangedAt,
            evidenceAt: evidenceAt,
            project: project ?? prior.project,
            hookEvent: hookEvent,
            context: SessionReturnContext.merging(
                prior: prior.context,
                newer: context
            ),
            evidencePrecedence: evidencePrecedence,
            evidenceID: evidenceID,
            evidenceOrdinal: evidenceOrdinal,
            equivalentEvidenceIDs: equivalentEvidenceIDs,
            equivalentEvidenceOverflow: equivalentEvidenceOverflow
        )
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
            isFresh: fresh,
            evidenceID: evidenceID,
            evidencePrecedence: evidencePrecedence,
            evidenceOrdinal: evidenceOrdinal,
            orderingKnown: orderingKnown
        )
    }

    private init(
        identity: SessionIdentity,
        status: SessionStatus,
        statusChangedAt: Date,
        evidenceAt: Date,
        project: String?,
        hookEvent: String?,
        context: SessionReturnContext?,
        evidencePrecedence: Int,
        evidenceID: String,
        evidenceOrdinal: UInt64?,
        equivalentEvidenceIDs: [String]?,
        equivalentEvidenceOverflow: Bool
    ) {
        self.identity = identity
        self.status = status
        self.statusChangedAt = statusChangedAt
        self.evidenceAt = evidenceAt
        self.project = project
        self.hookEvent = hookEvent
        self.context = context
        self.evidencePrecedence = evidencePrecedence
        self.evidenceID = evidenceID
        self.evidenceOrdinal = evidenceOrdinal
        self.equivalentEvidenceIDs = equivalentEvidenceIDs
        self.equivalentEvidenceOverflow = equivalentEvidenceOverflow
    }
}
