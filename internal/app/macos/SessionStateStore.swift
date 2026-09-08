import Darwin
import Foundation

enum SessionStateStoreError: Error, Equatable {
    case unsupportedVersion(Int)
    case corruptData(String)
    case readFailed(String)
    case writeFailed(String)
}

extension SessionStateStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            return "Unsupported session index version \(version)"
        case let .corruptData(reason):
            return "Session index is corrupt: \(reason)"
        case let .readFailed(reason):
            return "Could not read the session index: \(reason)"
        case let .writeFailed(reason):
            return "Could not write the session index: \(reason)"
        }
    }
}

final class SessionStateStore {
    private static let currentVersion = 1

    let url: URL
    private let fileManager: FileManager

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    var exists: Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func load() throws -> SessionStateIndex {
        guard exists else {
            return SessionStateIndex()
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SessionStateStoreError.readFailed(error.localizedDescription)
        }

        let snapshot: SessionStateSnapshot
        do {
            try validateSchema(data)
            snapshot = try Self.decoder.decode(SessionStateSnapshot.self, from: data)
        } catch {
            throw SessionStateStoreError.corruptData(error.localizedDescription)
        }
        guard snapshot.version == Self.currentVersion else {
            throw SessionStateStoreError.unsupportedVersion(snapshot.version)
        }

        do {
            return try SessionStateIndex(
                restoring: snapshot.sessions,
                nextEvidenceOrdinal: snapshot.nextEvidenceOrdinal,
                orderingNeedsRebuild: snapshot.nextEvidenceOrdinal == nil
            )
        } catch {
            throw SessionStateStoreError.corruptData(error.localizedDescription)
        }
    }

    func save(_ index: SessionStateIndex) throws {
        let snapshot = SessionStateSnapshot(
            version: Self.currentVersion,
            sessions: index.persistedRecords,
            nextEvidenceOrdinal: index.nextEvidenceOrdinal
        )
        let data: Data
        do {
            data = try Self.encoder.encode(snapshot)
        } catch {
            throw SessionStateStoreError.writeFailed(error.localizedDescription)
        }

        do {
            try createStoreDirectory()
            try writeAtomically(data)
        } catch let error as SessionStateStoreError {
            throw error
        } catch {
            throw SessionStateStoreError.writeFailed(error.localizedDescription)
        }
    }

    @discardableResult
    func recover(
        from events: [MewsEvent],
        now: Date,
        policy: SessionFreshnessPolicy = .standard,
        cliExecutablePath: String? = nil
    ) throws -> SessionStateIndex {
        let index = SessionStateIndex.rebuilding(
            from: events,
            now: now,
            policy: policy,
            cliExecutablePath: cliExecutablePath
        )
        try save(index)
        return index
    }

    @discardableResult
    func rebuildOrdering(
        from events: [MewsEvent],
        existing index: SessionStateIndex,
        now: Date,
        policy: SessionFreshnessPolicy = .standard,
        cliExecutablePath: String? = nil
    ) throws -> SessionStateIndex {
        var rebuilt = index
        _ = rebuilt.rebuildOrdering(
            from: events,
            now: now,
            policy: policy,
            cliExecutablePath: cliExecutablePath
        )
        try save(rebuilt)
        return rebuilt
    }

    @discardableResult
    func recover(
        from reload: EventReload,
        now: Date,
        policy: SessionFreshnessPolicy = .standard,
        cliExecutablePath: String? = nil
    ) throws -> SessionStateIndex {
        return try recover(
            from: reload.recoveryEvents,
            now: now,
            policy: policy,
            cliExecutablePath: cliExecutablePath
        )
    }

    private func createStoreDirectory() throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func validateSchema(_ data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SessionStateStoreError.corruptData(error.localizedDescription)
        }
        guard let snapshot = object as? [String: Any],
              ["version", "sessions"].allSatisfy({ snapshot[$0] != nil }),
              Set(snapshot.keys).isSubset(of: [
                "version", "sessions", "nextEvidenceOrdinal"
              ]),
              snapshot["version"] is NSNumber,
              let sessions = snapshot["sessions"] as? [[String: Any]] else {
            throw SessionStateStoreError.corruptData("unexpected snapshot schema")
        }
        if let next = snapshot["nextEvidenceOrdinal"] as? NSNumber,
           next.uint64Value == 0 {
            throw SessionStateStoreError.corruptData("invalid next evidence ordinal")
        }
        for record in sessions {
            guard Set(record.keys).isSubset(of: [
                "identity", "status", "statusChangedAt", "evidenceAt",
                "project", "hookEvent", "context", "evidencePrecedence",
                "evidenceID", "evidenceOrdinal", "equivalentEvidenceIDs",
                "equivalentEvidenceOverflow", "dismissedEvidenceID"
            ]) else {
                throw SessionStateStoreError.corruptData("unexpected session record schema")
            }
        }
    }

    private func writeAtomically(_ data: Data) throws {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SessionStateStoreError.writeFailed("could not create the atomic staging file")
        }

        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        guard rename(temporaryURL.path, url.path) == 0 else {
            throw SessionStateStoreError.writeFailed(
                String(cString: strerror(errno))
            )
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

final class SessionStateRepository {
    private let store: SessionStateStore
    private let policy: SessionFreshnessPolicy
    private let clock: () -> Date
    private let cliExecutablePath: String?
    private var index: SessionStateIndex
    private var needsStartupReconciliation = true

    init(
        store: SessionStateStore,
        policy: SessionFreshnessPolicy = .standard,
        clock: @escaping () -> Date = Date.init,
        cliExecutablePath: String? = nil
    ) throws {
        self.store = store
        self.policy = policy
        self.clock = clock
        self.cliExecutablePath = cliExecutablePath
        index = try store.load()
    }

    @discardableResult
    func apply(_ events: [MewsEvent]) throws -> Bool {
        var updated = index
        guard updated.apply(
            events,
            now: clock(),
            policy: policy,
            cliExecutablePath: cliExecutablePath
        ) else {
            return false
        }
        try store.save(updated)
        index = updated
        return true
    }

    @discardableResult
    func rebuildOrdering(from events: [MewsEvent]) throws -> Bool {
        guard !events.isEmpty else {
            return false
        }
        var updated = index
        let changed = updated.rebuildOrdering(
            from: events,
            now: clock(),
            policy: policy,
            cliExecutablePath: cliExecutablePath
        )
        guard changed else {
            return false
        }
        try store.save(updated)
        index = updated
        return true
    }

    @discardableResult
    func apply(_ reload: EventReload) throws -> Bool {
        return try applyWithResult(reload).changed
    }

    func applyWithResult(
        _ reload: EventReload
    ) throws -> SessionStateApplicationResult {
        if reload.sessionDidResync {
            let changed = try rebuildOrdering(from: reload.sessionResyncEvents)
            needsStartupReconciliation = false
            return SessionStateApplicationResult(
                changed: changed,
                stopTransitionIdentifier: nil
            )
        }
        let recovering = needsStartupReconciliation
        let events = recovering
            ? reload.recoveryEvents
            : reload.newEvents
        var updated = index
        let result = updated.applyTrackingStopTransitions(
            events,
            now: clock(),
            policy: policy,
            cliExecutablePath: cliExecutablePath
        )
        if result.changed {
            try store.save(updated)
            index = updated
        }
        needsStartupReconciliation = false
        return SessionStateApplicationResult(
            changed: result.changed,
            stopTransitionIdentifier: recovering
                ? nil
                : result.stopTransitionIdentifier
        )
    }

    func currentSessions() -> [CurrentSessionState] {
        return index.currentSessions(
            now: clock(),
            policy: policy,
            cliExecutablePath: cliExecutablePath
        )
    }

    func currentSession(for identity: SessionIdentity) -> CurrentSessionState? {
        return currentSessions().first { $0.identity == identity }
    }

    var sessionCount: Int {
        index.count
    }

    var orderingKnown: Bool {
        !index.orderingNeedsRebuild &&
            index.persistedRecords.allSatisfy(\.orderingKnown)
    }

    func snapshot() -> [CurrentSessionState] {
        currentSessions()
    }

    @discardableResult
    func dismiss(_ request: SessionDismissalRequest) throws -> SessionDismissalResult {
        var updated = index
        let result = updated.dismiss(
            request,
            now: clock(),
            policy: policy,
            cliExecutablePath: cliExecutablePath
        )
        guard result == .dismissed else {
            return result
        }
        try store.save(updated)
        index = updated
        return result
    }

    @discardableResult
    func dismiss(
        _ request: SessionDismissalRequest,
        after scan: SessionEvidenceScan
    ) throws -> SessionDismissalResult {
        var updated = index
        if scan.didResync {
            _ = updated.rebuildOrdering(
                from: scan.events,
                now: clock(),
                policy: policy,
                cliExecutablePath: cliExecutablePath
            )
        } else {
            _ = updated.apply(
                scan.events,
                now: clock(),
                policy: policy,
                cliExecutablePath: cliExecutablePath
            )
        }
        let reconciled = updated != index
        let result = updated.dismiss(
            request,
            now: clock(),
            policy: policy,
            cliExecutablePath: cliExecutablePath
        )
        if reconciled || result == .dismissed {
            try store.save(updated)
            index = updated
        }
        needsStartupReconciliation = false
        return result
    }
}

private struct SessionStateSnapshot: Codable {
    let version: Int
    let sessions: [SessionStateRecord]
    let nextEvidenceOrdinal: UInt64?
}
