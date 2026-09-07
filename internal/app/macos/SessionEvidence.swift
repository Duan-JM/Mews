import Foundation

struct SessionEvidence {
    static let maximumEquivalentIDs = 64

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

    var orderingKey: SessionEvidenceOrderingKey {
        SessionEvidenceOrderingKey(timestamp: timestamp, precedence: precedence)
    }

    func isNewer(than record: SessionStateRecord) -> Bool {
        if id == record.evidenceID || record.equivalentEvidenceIDs?.contains(id) == true {
            return false
        }
        if timestamp != record.evidenceAt {
            return timestamp > record.evidenceAt
        }
        if precedence != record.evidencePrecedence {
            return precedence > record.evidencePrecedence
        }
        if !record.orderingKnown {
            return false
        }
        return !record.equivalentEvidenceOverflow
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

struct SessionEvidenceOrderingKey: Equatable, Comparable {
    let timestamp: Date
    let precedence: Int

    static func < (
        left: SessionEvidenceOrderingKey,
        right: SessionEvidenceOrderingKey
    ) -> Bool {
        if left.timestamp != right.timestamp {
            return left.timestamp < right.timestamp
        }
        return left.precedence < right.precedence
    }
}
