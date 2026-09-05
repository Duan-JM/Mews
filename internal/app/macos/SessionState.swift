import Foundation

struct SessionStateIndex: Equatable {
    private var records: [SessionIdentity: SessionStateRecord] = [:]
    private(set) var nextEvidenceOrdinal: UInt64 = 1
    private(set) var orderingNeedsRebuild = false

    var count: Int {
        records.count
    }

    init() {}

    init(restoring persistedRecords: [SessionStateRecord]) throws {
        var ordinals = Set<UInt64>()
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
            if record.orderingKnown {
                guard let ordinal = record.evidenceOrdinal,
                      ordinal < UInt64.max - 1,
                      ordinals.insert(ordinal).inserted else {
                    throw SessionStateValidationError.invalidOrdering
                }
                nextEvidenceOrdinal = max(
                    nextEvidenceOrdinal,
                    (record.evidenceOrdinal ?? 0) + 1
                )
            } else {
                orderingNeedsRebuild = true
            }
        }
    }

    init(
        restoring persistedRecords: [SessionStateRecord],
        nextEvidenceOrdinal: UInt64?,
        orderingNeedsRebuild: Bool
    ) throws {
        try self.init(restoring: persistedRecords)
        if let nextEvidenceOrdinal {
            guard nextEvidenceOrdinal >= self.nextEvidenceOrdinal,
                  nextEvidenceOrdinal < UInt64.max else {
                throw SessionStateValidationError.invalidOrdering
            }
            self.nextEvidenceOrdinal = nextEvidenceOrdinal
        } else {
            self.orderingNeedsRebuild = true
            records = records.mapValues { $0.withUnknownOrdering() }
        }
        self.orderingNeedsRebuild = self.orderingNeedsRebuild || orderingNeedsRebuild
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
                if let leftOrdinal = $0.evidenceOrdinal,
                   let rightOrdinal = $1.evidenceOrdinal,
                   leftOrdinal != rightOrdinal {
                    return leftOrdinal > rightOrdinal
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
        if let current, !replacesFutureRecord {
            guard evidence.isNewer(than: current) else {
                return false
            }
        }

        let tie = equivalentEvidence(
            for: evidence,
            replacing: replacesFutureRecord ? nil : current
        )
        _ = compactEvidenceOrdinalsIfNeeded()
        let ordinal = nextEvidenceOrdinal
        guard ordinal > 0, ordinal < UInt64.max else {
            orderingNeedsRebuild = true
            return false
        }
        nextEvidenceOrdinal += 1
        records[identity] = SessionStateRecord(
            replacing: replacesFutureRecord ? nil : current,
            identity: identity,
            status: status,
            evidence: evidence,
            project: normalizedText(event.project),
            hookEvent: normalizedText(event.hookEvent),
            context: SessionReturnContext(
                payload: event.cliContext(cliExecutablePath: cliExecutablePath)
            ),
            evidenceOrdinal: ordinal,
            equivalentEvidenceIDs: tie.ids,
            equivalentEvidenceOverflow: tie.overflow
        )
        return true
    }

    private func equivalentEvidence(
        for evidence: SessionEvidence,
        replacing current: SessionStateRecord?
    ) -> (ids: [String], overflow: Bool) {
        guard let current,
              current.evidenceAt == evidence.timestamp,
              current.evidencePrecedence == evidence.precedence else {
            return ([evidence.id], false)
        }
        let priorIDs = current.equivalentEvidenceIDs ?? [current.evidenceID]
        let allIDs = priorIDs + [evidence.id]
        return (
            Array(allIDs.suffix(SessionEvidence.maximumEquivalentIDs)),
            current.equivalentEvidenceOverflow ||
                allIDs.count > SessionEvidence.maximumEquivalentIDs
        )
    }

    private mutating func compactEvidenceOrdinalsIfNeeded() -> Bool {
        guard nextEvidenceOrdinal >= UInt64.max - 1 else {
            return false
        }
        let orderedIdentities = records.values
            .filter(\.orderingKnown)
            .sorted {
                if $0.evidenceOrdinal != $1.evidenceOrdinal {
                    return ($0.evidenceOrdinal ?? 0) < ($1.evidenceOrdinal ?? 0)
                }
                return $0.identity < $1.identity
            }
            .map(\.identity)
        for (offset, identity) in orderedIdentities.enumerated() {
            records[identity]?.evidenceOrdinal = UInt64(offset + 1)
        }
        nextEvidenceOrdinal = UInt64(orderedIdentities.count + 1)
        return true
    }

    var persistedRecords: [SessionStateRecord] {
        return records.values.sorted { $0.identity < $1.identity }
    }
}

extension SessionStateIndex {
    mutating func rebuildOrdering(
        from events: [MewsEvent],
        now: Date,
        policy: SessionFreshnessPolicy = .standard,
        cliExecutablePath: String? = nil
    ) -> Bool {
        let compacted = compactEvidenceOrdinalsIfNeeded()
        let replay = replayProjection(
            events,
            now: now,
            policy: policy,
            cliExecutablePath: cliExecutablePath
        )
        let merged = mergingReplay(
            replay,
            now: now,
            policy: policy
        )
        let changed = compacted || merged != records || orderingNeedsRebuild
        records = merged
        nextEvidenceOrdinal = max(
            replay.index.nextEvidenceOrdinal,
            records.values.compactMap(\.evidenceOrdinal).max().map { $0 + 1 } ?? 1
        )
        orderingNeedsRebuild = records.values.contains { !$0.orderingKnown }
        return changed
    }

    private func replayProjection(
        _ events: [MewsEvent],
        now: Date,
        policy: SessionFreshnessPolicy,
        cliExecutablePath: String?
    ) -> SessionReplayProjection {
        var projection = SessionStateIndex()
        projection.nextEvidenceOrdinal = nextEvidenceOrdinal
        var acceptedEvidence: [SessionIdentity: [SessionReplayEvidence]] = [:]
        for event in events {
            let identity = SessionIdentity(source: event.source, sessionID: event.sessionID)
            let status = SessionStatus(rawValue: event.status)
            guard projection.apply(
                event,
                now: now,
                policy: policy,
                cliExecutablePath: cliExecutablePath
            ), let identity, let status else {
                continue
            }
            let evidence = SessionEvidence(event: event, status: status)
            acceptedEvidence[identity, default: []].append(
                SessionReplayEvidence(
                    status: status,
                    orderingKey: evidence.orderingKey,
                    id: evidence.id
                )
            )
        }
        return SessionReplayProjection(
            index: projection,
            acceptedEvidence: acceptedEvidence
        )
    }

    private func mergingReplay(
        _ replay: SessionReplayProjection,
        now: Date,
        policy: SessionFreshnessPolicy
    ) -> [SessionIdentity: SessionStateRecord] {
        var merged = records
        for (identity, candidate) in replay.index.records {
            guard let existing = records[identity] else {
                merged[identity] = candidate
                continue
            }
            if !policy.acceptsEvidence(evidenceAt: existing.evidenceAt, now: now) {
                merged[identity] = candidate
                continue
            }
            if candidate.evidenceID == existing.evidenceID {
                merged[identity] = existing.orderingKnown
                    ? existing.mergingEquivalentEvidence(from: candidate)
                    : existing.attachingOrdering(from: candidate)
                continue
            }
            if candidate.orderingKey > existing.orderingKey {
                merged[identity] = candidate.mergingPersistedMetadata(
                    from: existing,
                    replayProvesStatusTransition: replay.provesStatusTransition(
                        for: identity,
                        after: existing
                    )
                )
                continue
            }
            if candidate.orderingKey == existing.orderingKey,
               existing.equivalentEvidenceOverflow {
                continue
            }
            if candidate.orderingKey == existing.orderingKey,
               candidate.equivalentEvidenceIDs?.contains(existing.evidenceID) == true {
                merged[identity] = candidate.mergingPersistedMetadata(
                    from: existing,
                    replayProvesStatusTransition: replay.provesStatusTransition(
                        for: identity,
                        after: existing
                    )
                )
                continue
            }
            if candidate.orderingKey == existing.orderingKey {
                merged[identity] = existing.withUnknownOrdering()
            }
        }
        return merged
    }
}

private struct SessionReplayProjection {
    let index: SessionStateIndex
    let acceptedEvidence: [SessionIdentity: [SessionReplayEvidence]]

    func provesStatusTransition(
        for identity: SessionIdentity,
        after existing: SessionStateRecord
    ) -> Bool {
        var passedExistingEvidence = false
        for evidence in acceptedEvidence[identity] ?? [] {
            if evidence.id == existing.evidenceID {
                passedExistingEvidence = true
                continue
            }
            if passedExistingEvidence || evidence.orderingKey > existing.orderingKey,
               evidence.status != existing.status {
                return true
            }
        }
        return false
    }
}

private struct SessionReplayEvidence {
    let status: SessionStatus
    let orderingKey: SessionEvidenceOrderingKey
    let id: String
}
