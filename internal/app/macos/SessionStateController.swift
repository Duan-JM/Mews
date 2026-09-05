import Foundation

struct SessionControllerSnapshot: Equatable {
    let revision: UInt64
    let sessions: [CurrentSessionState]
    let reconciliationAnchor: SessionReconciliationAnchor?
    let orderingKnown: Bool
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
        completion: @escaping (Result<SessionControllerSnapshot, Error>) -> Void
    ) {
        queue.async {
            completion(Result {
                let scan: SessionEvidenceScan
                do {
                    scan = try self.evidenceReader.scan(anchor: self.anchor)
                } catch EventLogReadError.missingFile {
                    self.revision += 1
                    return self.makeSnapshot()
                }
                let sessionReload = EventReload(
                    events: reload.events,
                    newEvents: scan.didResync ? [] : scan.events,
                    recoveryEvents: scan.events,
                    sessionResyncEvents: scan.didResync ? scan.events : [],
                    sessionCandidateAnchor: scan.candidateAnchor,
                    sessionDidResync: scan.didResync
                )
                _ = try self.repository.apply(sessionReload)
                self.anchor = scan.candidateAnchor
                self.revision += 1
                return self.makeSnapshot()
            })
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

    private func makeSnapshot() -> SessionControllerSnapshot {
        return SessionControllerSnapshot(
            revision: revision,
            sessions: repository.snapshot(),
            reconciliationAnchor: anchor,
            orderingKnown: repository.orderingKnown
        )
    }
}
