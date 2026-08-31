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

private enum SessionPresentationSlot: Hashable {
    case tmux(socketPath: String, paneID: String)
    case kitty(listenOn: String, windowID: String)
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
    let health: RuntimeHealthPresentation?

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
        fileManager: FileManager = .default
    ) -> SessionPresentation {
        let attentionByIdentity = Dictionary(
            uniqueKeysWithValues: attentionRecords.map { ($0.identity, $0) }
        )
        let rows = latestSessionsByTerminalSlot(sessions, now: now).filter {
            isDisplayable(session: $0, now: now)
        }.map { session in
            row(
                session: session,
                attentionRecord: attentionByIdentity[session.identity],
                fileManager: fileManager
            )
        }.sorted(by: rowPrecedes)
        return SessionPresentation(
            rows: rows,
            health: healthSnapshot.flatMap { health(snapshot: $0, now: now) }
        )
    }

    private static func latestSessionsByTerminalSlot(
        _ sessions: [CurrentSessionState],
        now: Date
    ) -> [CurrentSessionState] {
        let tolerance = SessionFreshnessPolicy.standard.futureTolerance
        let eligible = sessions.filter {
            now.timeIntervalSince($0.evidenceAt) >= -tolerance
        }
        let withoutSlot = eligible.filter { presentationSlot(for: $0) == nil }
        let bySlot = Dictionary(grouping: eligible.compactMap { session in
            presentationSlot(for: session).map { ($0, session) }
        }, by: \.0)

        return withoutSlot + bySlot.values.flatMap { entries in
            let newestEvidenceAt = entries.map(\.1.evidenceAt).max()
            return entries.compactMap { _, session in
                session.evidenceAt == newestEvidenceAt ? session : nil
            }
        }
    }

    private static func presentationSlot(
        for session: CurrentSessionState
    ) -> SessionPresentationSlot? {
        if let target = session.returnContext?.tmuxTarget {
            return .tmux(socketPath: target.socketPath, paneID: target.paneID)
        }
        if let target = session.returnContext?.kittyTarget {
            return .kitty(listenOn: target.listenOn, windowID: target.windowID)
        }
        return nil
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
            )
        )
    }

    private static func isDisplayable(
        session: CurrentSessionState,
        now: Date
    ) -> Bool {
        let age = now.timeIntervalSince(session.evidenceAt)
        let policy = SessionFreshnessPolicy.standard
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
