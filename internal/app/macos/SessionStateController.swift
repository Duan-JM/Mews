import Foundation

struct SessionControllerSnapshot: Equatable {
    let revision: UInt64
    let sessions: [CurrentSessionState]
    let reconciliationAnchor: SessionReconciliationAnchor?
    let orderingKnown: Bool
    let stopTransitionIdentifier: String?

    init(
        revision: UInt64,
        sessions: [CurrentSessionState],
        reconciliationAnchor: SessionReconciliationAnchor?,
        orderingKnown: Bool,
        stopTransitionIdentifier: String? = nil
    ) {
        self.revision = revision
        self.sessions = sessions
        self.reconciliationAnchor = reconciliationAnchor
        self.orderingKnown = orderingKnown
        self.stopTransitionIdentifier = stopTransitionIdentifier
    }
}

enum SessionControllerReconciliation {
    case success(SessionControllerSnapshot)
    case failure(Error, SessionControllerSnapshot)

    func get() throws -> SessionControllerSnapshot {
        switch self {
        case let .success(snapshot):
            return snapshot
        case let .failure(error, _):
            throw error
        }
    }
}

final class SessionStateController {
    private let queue = DispatchQueue(
        label: "dev.mews.session-state",
        qos: .userInitiated
    )
    private let repository: SessionStateRepository
    private let evidenceReader: SessionEvidenceReader
    private var anchor: SessionReconciliationAnchor?
    private var revision: UInt64 = 0

    init(
        storeDirectory: URL,
        eventsURL: URL? = nil,
        clock: @escaping () -> Date = Date.init,
        cliExecutablePath: String? = nil
    ) throws {
        repository = try SessionStateRepository(
            store: SessionStateStore(
                url: storeDirectory.appendingPathComponent("sessions.json")
            ),
            clock: clock,
            cliExecutablePath: cliExecutablePath
        )
        evidenceReader = SessionEvidenceReader(
            url: eventsURL ?? storeDirectory.appendingPathComponent("events.jsonl")
        )
    }

    func reconcile(
        _ reload: EventReload,
        completion: @escaping (SessionControllerReconciliation) -> Void
    ) {
        queue.async {
            do {
                completion(.success(try self.reconcileSynchronously(reload)))
            } catch {
                completion(.failure(error, self.makeSnapshot()))
            }
        }
    }

    func snapshot(
        completion: @escaping (SessionControllerSnapshot) -> Void
    ) {
        queue.async {
            completion(self.makeSnapshot())
        }
    }

    func orderedEvidenceScan(
        completion: @escaping (Result<SessionEvidenceScan, Error>) -> Void
    ) {
        queue.async {
            completion(Result {
                try self.evidenceReader.scan(anchor: self.anchor)
            })
        }
    }

    func dismiss(
        _ request: SessionDismissalRequest,
        completion: @escaping (Result<SessionDismissalResponse, Error>) -> Void
    ) {
        queue.async {
            do {
                let scan = try self.evidenceReader.scan(anchor: self.anchor)
                let result = try self.repository.dismiss(request, after: scan)
                self.anchor = scan.candidateAnchor
                self.revision += 1
                completion(.success(SessionDismissalResponse(
                    result: result,
                    snapshot: self.makeSnapshot()
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func makeSnapshot(
        stopTransitionIdentifier: String? = nil
    ) -> SessionControllerSnapshot {
        return SessionControllerSnapshot(
            revision: revision,
            sessions: repository.snapshot(),
            reconciliationAnchor: anchor,
            orderingKnown: repository.orderingKnown,
            stopTransitionIdentifier: stopTransitionIdentifier
        )
    }

    private func reconcileSynchronously(
        _ reload: EventReload
    ) throws -> SessionControllerSnapshot {
        guard let boundary = reload.sessionCandidateAnchor else {
            revision += 1
            return makeSnapshot()
        }
        if let anchor,
           anchor.fileIdentity == boundary.fileIdentity,
           boundary.offset < anchor.offset,
           try !evidenceReader.matchesCurrentFile(boundary) {
            revision += 1
            return makeSnapshot()
        }
        let scan = try evidenceReader.scan(
            anchor: anchor,
            through: boundary,
            forceFull: reload.sessionDidResync
        )
        let sessionReload = EventReload(
            events: reload.events,
            newEvents: scan.didResync ? [] : scan.events,
            recoveryEvents: scan.events,
            sessionResyncEvents: scan.didResync ? scan.events : [],
            sessionCandidateAnchor: scan.candidateAnchor,
            sessionDidResync: scan.didResync
        )
        let result = try repository.applyWithResult(sessionReload)
        anchor = scan.candidateAnchor
        revision += 1
        return makeSnapshot(
            stopTransitionIdentifier: result.stopTransitionIdentifier
        )
    }
}
