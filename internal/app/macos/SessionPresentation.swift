import Foundation

enum SessionPresentationPriority: Int, Comparable {
    case needsInput
    case failed
    case running
    case unacknowledgedDone
    case recent

    static func < (
        left: SessionPresentationPriority,
        right: SessionPresentationPriority
    ) -> Bool {
        return left.rawValue < right.rawValue
    }
}

struct SessionPresentationRowID: Hashable {
    let identity: SessionIdentity
    let evidenceID: String
}

struct SessionPresentationRow: Equatable {
    let identity: SessionIdentity
    let status: SessionStatus
    let sourceLabel: String
    let projectLabel: String?
    let sessionLabel: String
    let statusLabel: String
    let statusCode: String
    let returnContext: CLIContextPayload?
    let evidenceAt: Date
    let priority: SessionPresentationPriority
    let evidenceID: String
    let dismissalRequest: SessionDismissalRequest?

    init(
        identity: SessionIdentity,
        status: SessionStatus,
        sourceLabel: String,
        projectLabel: String?,
        sessionLabel: String,
        statusLabel: String,
        statusCode: String,
        returnContext: CLIContextPayload?,
        evidenceAt: Date,
        priority: SessionPresentationPriority,
        evidenceID: String = "",
        dismissalRequest: SessionDismissalRequest? = nil
    ) {
        self.identity = identity
        self.status = status
        self.sourceLabel = sourceLabel
        self.projectLabel = projectLabel
        self.sessionLabel = sessionLabel
        self.statusLabel = statusLabel
        self.statusCode = statusCode
        self.returnContext = returnContext
        self.evidenceAt = evidenceAt
        self.priority = priority
        self.evidenceID = evidenceID
        self.dismissalRequest = dismissalRequest
    }

    var id: SessionPresentationRowID {
        return SessionPresentationRowID(
            identity: identity,
            evidenceID: evidenceID
        )
    }

    var returnCommand: String? {
        return returnContext?.returnCommand
    }

    var returnActionLabel: String {
        return returnContext?.codexAppURL == nil ? "RETURN" : "OPEN"
    }

    var returnActionDescription: String {
        return returnContext?.codexAppURL == nil
            ? "Return to CLI"
            : "Open in Codex"
    }

    var primaryLabel: String {
        let source = sourceLabel.uppercased()
        guard let projectLabel else {
            return source
        }
        let separator = "  ·  "
        let remaining = max(
            0,
            30 - notchDisplayColumnCount(source) -
                notchDisplayColumnCount(separator)
        )
        guard let boundedProject = notchDisplayText(
            projectLabel,
            maximumColumns: remaining
        ) else {
            return source
        }
        return "\(source)\(separator)\(boundedProject)"
    }

    var menuTitle: String {
        var metadata = [sourceLabel]
        if let projectLabel {
            metadata.append(projectLabel)
        }
        metadata.append(sessionLabel)
        return "\(statusCode)  \(metadata.joined(separator: " · "))"
    }

    var accessibilityLabel: String {
        var parts = [sourceLabel]
        if let projectLabel {
            parts.append(projectLabel)
        }
        parts.append("session \(sessionLabel)")
        parts.append(statusLabel)
        parts.append(
            returnContext == nil
                ? "Return to CLI unavailable"
                : "\(returnActionDescription) available"
        )
        return parts.joined(separator: ", ")
    }
}

extension SessionStatus {
    var sessionPresentationLabel: String {
        return self == .done ? "Stopped" : mewsStatusLabel(rawValue)
    }

    var sessionPresentationCode: String {
        switch self {
        case .idle:
            return "IDLE"
        case .running:
            return "RUN"
        case .needsInput:
            return "ASK"
        case .done:
            return "STOP"
        case .failed:
            return "FAIL"
        }
    }
}

extension CurrentSessionState {
    var sessionPresentationLabel: String {
        return isSubagentRunning ? "Subagent Running" : presentationStatus.sessionPresentationLabel
    }

    var sessionPresentationCode: String {
        return isSubagentRunning ? "SUB" : presentationStatus.sessionPresentationCode
    }
}

struct RuntimeHealthPresentation: Equatable {
    let state: RuntimeHealthState
    let capabilityID: String
    let title: String
    let message: String
    let recovery: String?
    let additionalCount: Int

    var statusCode: String {
        return state == .blocked ? "BLOCKED" : "DEGRADED"
    }

    var accessibilityLabel: String {
        var parts = ["Health \(statusCode.lowercased())", title, message]
        if recovery != nil {
            parts.append("Recovery instruction available")
        }
        return parts.joined(separator: ", ")
    }
}

struct SessionPresentation: Equatable {
    static let menuLimit = 5

    let rows: [SessionPresentationRow]
    let aggregateStatuses: [SessionStatus]
    let health: RuntimeHealthPresentation?
    let sessionRevision: UInt64?

    init(
        rows: [SessionPresentationRow],
        aggregateStatuses: [SessionStatus]? = nil,
        health: RuntimeHealthPresentation?,
        sessionRevision: UInt64? = nil
    ) {
        self.rows = rows
        self.aggregateStatuses = aggregateStatuses ?? rows.map(\.status)
        self.health = health
        self.sessionRevision = sessionRevision
    }

    var menuRows: [SessionPresentationRow] {
        return Array(rows.prefix(Self.menuLimit))
    }
}

struct SessionPresentationPolicy {
    static func resolve(
        sessions: [CurrentSessionState],
        attentionRecords: [AttentionRecord],
        healthSnapshot: RuntimeHealthSnapshot?,
        now: Date,
        sessionRevision: UInt64? = nil,
        fileManager: FileManager = .default
    ) -> SessionPresentation {
        let attentionByIdentity = Dictionary(
            uniqueKeysWithValues: attentionRecords.map { ($0.identity, $0) }
        )
        let candidates = SessionDismissalPolicy.displayableWinners(
            from: sessions,
            now: now
        )
        let presentedSessions = candidates.filter { session in
            !SessionDismissalPolicy.isDismissed(session) ||
                SessionDismissalPolicy.eligibility(
                    for: session,
                    among: sessions,
                    now: now
                ) != .eligible
        }
        let rows = presentedSessions.map { session in
            row(
                session: session,
                allSessions: sessions,
                now: now,
                attentionRecord: attentionByIdentity[session.identity],
                fileManager: fileManager
            )
        }.sorted(by: rowPrecedes)
        return SessionPresentation(
            rows: rows,
            aggregateStatuses: presentedSessions.map(\.status),
            health: healthSnapshot.flatMap { health(snapshot: $0, now: now) },
            sessionRevision: sessionRevision
        )
    }

    static func stabilizedRows(
        canonical: [SessionPresentationRow],
        previous: [SessionPresentationRow]
    ) -> [SessionPresentationRow] {
        let canonicalByIdentity = Dictionary(
            uniqueKeysWithValues: canonical.map { ($0.identity, $0) }
        )
        var retained = previous.compactMap { row in
            canonicalByIdentity[row.identity]
        }
        let retainedIdentities = Set(retained.map(\.identity))
        retained.append(
            contentsOf: canonical.filter { !retainedIdentities.contains($0.identity) }
        )
        return retained
    }

    private static func row(
        session: CurrentSessionState,
        allSessions: [CurrentSessionState],
        now: Date,
        attentionRecord: AttentionRecord?,
        fileManager: FileManager
    ) -> SessionPresentationRow {
        let status = session.presentationStatus
        let matchingAttention = attentionRecord.flatMap { record in
            record.key.status == status &&
                record.key.statusChangedAt == session.statusChangedAt
                ? record
                : nil
        }

        return SessionPresentationRow(
            identity: session.identity,
            status: status,
            sourceLabel: notchDisplayText(
                mewsSourceLabel(session.source),
                maximumColumns: 18
            ) ?? "Agent",
            projectLabel: notchProjectLabel(session.project),
            sessionLabel: notchSessionLabel(session.sessionID) ?? "unknown",
            statusLabel: session.sessionPresentationLabel,
            statusCode: session.sessionPresentationCode,
            returnContext: session.returnContext?.actionable(fileManager: fileManager),
            evidenceAt: session.evidenceAt,
            priority: priority(
                status: status,
                hasCurrentCompletion: session.status == .done,
                attention: matchingAttention
            ),
            evidenceID: session.evidenceID,
            dismissalRequest: dismissalRequest(
                session: session,
                allSessions: allSessions,
                now: now
            )
        )
    }

    private static func dismissalRequest(
        session: CurrentSessionState,
        allSessions: [CurrentSessionState],
        now: Date
    ) -> SessionDismissalRequest? {
        guard SessionDismissalPolicy.eligibility(
            for: session,
            among: allSessions,
            now: now
        ) == .eligible else {
            return nil
        }
        return SessionDismissalRequest(
            identity: session.identity,
            evidenceID: session.evidenceID
        )
    }

    private static func priority(
        status: SessionStatus,
        hasCurrentCompletion: Bool,
        attention: AttentionRecord?
    ) -> SessionPresentationPriority {
        switch status {
        case .needsInput:
            return .needsInput
        case .failed:
            return .failed
        case .done:
            guard hasCurrentCompletion else {
                return .recent
            }
            switch attention?.disposition {
            case .acknowledged, .resolved:
                return .recent
            case .delivered, nil:
                return .unacknowledgedDone
            }
        case .running:
            return .running
        case .idle:
            return .recent
        }
    }

    private static func rowPrecedes(
        left: SessionPresentationRow,
        right: SessionPresentationRow
    ) -> Bool {
        if left.priority != right.priority {
            return left.priority < right.priority
        }
        if left.evidenceAt != right.evidenceAt {
            return left.evidenceAt > right.evidenceAt
        }
        return left.identity < right.identity
    }

    private static func health(
        snapshot: RuntimeHealthSnapshot,
        now: Date
    ) -> RuntimeHealthPresentation? {
        let effectiveState = snapshot.effectiveState(at: now)
        guard effectiveState == .degraded || effectiveState == .blocked else {
            return nil
        }
        let affected = snapshot.affectedCapabilities
            .filter { $0.state == .blocked || $0.state == .degraded }
            .sorted(by: healthCapabilityPrecedes)
        guard let capability = affected.first else {
            return nil
        }
        return RuntimeHealthPresentation(
            state: capability.state,
            capabilityID: capability.id,
            title: notchDisplayText(capability.name, maximumColumns: 24) ?? "Runtime health",
            message: notchDisplayText(
                capability.message,
                maximumColumns: capability.recovery == nil ? 48 : 36
            ) ?? "Capability affected",
            recovery: capability.recovery,
            additionalCount: max(0, affected.count - 1)
        )
    }

    private static func healthCapabilityPrecedes(
        left: RuntimeHealthCapability,
        right: RuntimeHealthCapability
    ) -> Bool {
        if left.state != right.state {
            return left.state == .blocked
        }
        if left.kind != right.kind {
            return left.kind == .functional
        }
        return left.id < right.id
    }
}
