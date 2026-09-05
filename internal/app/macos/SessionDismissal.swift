import Foundation

enum SessionTerminalSlot: Hashable {
    case tmux(socketPath: String, paneID: String)
    case kitty(listenOn: String, windowID: String)
}

struct SessionDismissalRequest: Equatable {
    let identity: SessionIdentity
    let evidenceID: String
}

enum SessionDismissalResult: Equatable {
    case dismissed
    case alreadyDismissed
    case staleEvidence
    case ineligibleState
    case orderingUnavailable
}

struct SessionDismissalResponse: Equatable {
    let result: SessionDismissalResult
    let snapshot: SessionControllerSnapshot
}

enum SessionDismissalEligibility: Equatable {
    case eligible
    case orderingUnavailable
    case ineligibleState
}

enum SessionDismissalPolicy {
    static func displayableWinners(
        from sessions: [CurrentSessionState],
        now: Date,
        policy: SessionFreshnessPolicy = .standard
    ) -> [CurrentSessionState] {
        let eligible = sessions.filter {
            now.timeIntervalSince($0.evidenceAt) >= -policy.futureTolerance
        }
        let withoutSlot = eligible
            .filter { terminalSlot(for: $0) == nil }
            .filter {
                SessionVisibilityPolicy.isDisplayable(
                    session: $0,
                    now: now,
                    policy: policy
                )
            }
        let grouped = Dictionary(grouping: eligible.compactMap { session in
            terminalSlot(for: session).map { ($0, session) }
        }, by: \.0)
        return withoutSlot + grouped.values.flatMap { entries in
            selection(for: entries.map(\.1)).filter {
                SessionVisibilityPolicy.isDisplayable(
                    session: $0,
                    now: now,
                    policy: policy
                )
            }
        }
    }

    static func eligibility(
        for target: CurrentSessionState,
        among sessions: [CurrentSessionState],
        now: Date,
        policy: SessionFreshnessPolicy = .standard
    ) -> SessionDismissalEligibility {
        guard target.identity.source.isEmpty == false,
              target.identity.sessionID.isEmpty == false,
              normalizedText(target.evidenceID) == target.evidenceID,
              target.evidenceID.isEmpty == false else {
            return .ineligibleState
        }
        guard SessionVisibilityPolicy.isDisplayable(
            session: target,
            now: now,
            policy: policy
        ), target.presentationStatus == .done else {
            return .ineligibleState
        }
        guard target.orderingKnown, !target.equivalentEvidenceOverflow else {
            return .orderingUnavailable
        }

        guard let slot = terminalSlot(for: target) else {
            return .eligible
        }
        let candidates = sessions.filter {
            terminalSlot(for: $0) == slot &&
                now.timeIntervalSince($0.evidenceAt) >= -policy.futureTolerance
        }
        switch selectionResult(for: candidates) {
        case let .winner(winner):
            return winner.identity == target.identity &&
                winner.evidenceID == target.evidenceID
                ? .eligible
                : .ineligibleState
        case let .unresolved(tied):
            return tied.contains {
                $0.identity == target.identity &&
                    $0.evidenceID == target.evidenceID
            } ? .orderingUnavailable : .ineligibleState
        }
    }

    static func isDismissed(_ session: CurrentSessionState) -> Bool {
        return session.isDismissed
    }

    static func terminalSlot(
        for session: CurrentSessionState
    ) -> SessionTerminalSlot? {
        if let target = session.returnContext?.tmuxTarget {
            return .tmux(socketPath: target.socketPath, paneID: target.paneID)
        }
        if let target = session.returnContext?.kittyTarget {
            return .kitty(listenOn: target.listenOn, windowID: target.windowID)
        }
        return nil
    }

    private enum Selection {
        case winner(CurrentSessionState)
        case unresolved([CurrentSessionState])
    }

    private static func selection(
        for candidates: [CurrentSessionState]
    ) -> [CurrentSessionState] {
        switch selectionResult(for: candidates) {
        case let .winner(winner):
            return [winner]
        case let .unresolved(tied):
            return tied
        }
    }

    private static func selectionResult(
        for candidates: [CurrentSessionState]
    ) -> Selection {
        guard let highestKey = candidates.map(\.orderingKey).max() else {
            return .unresolved([])
        }
        let highest = candidates.filter { $0.orderingKey == highestKey }
        guard highest.count > 1 else {
            return .winner(highest[0])
        }
        guard highest.allSatisfy({
            $0.orderingKnown &&
                !$0.equivalentEvidenceOverflow &&
                $0.evidenceOrdinal != nil
        }) else {
            return .unresolved(highest)
        }
        let sorted = highest.sorted {
            ($0.evidenceOrdinal ?? 0) > ($1.evidenceOrdinal ?? 0)
        }
        guard sorted.dropFirst().allSatisfy({
            $0.evidenceOrdinal != sorted[0].evidenceOrdinal
        }) else {
            return .unresolved(highest)
        }
        return .winner(sorted[0])
    }
}

private extension CurrentSessionState {
    var orderingKey: SessionEvidenceOrderingKey {
        SessionEvidenceOrderingKey(
            timestamp: evidenceAt,
            precedence: evidencePrecedence
        )
    }
}
