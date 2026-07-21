import Darwin
import Foundation

enum AttentionStateStoreError: Error, Equatable {
    case unsupportedVersion(Int)
    case corruptData(String)
    case readFailed(String)
    case writeFailed(String)
}

extension AttentionStateStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            return "Unsupported attention state version \(version)"
        case let .corruptData(reason):
            return "Attention state is corrupt: \(reason)"
        case let .readFailed(reason):
            return "Could not read attention state: \(reason)"
        case let .writeFailed(reason):
            return "Could not write attention state: \(reason)"
        }
    }
}

final class AttentionStateStore {
    private static let currentVersion = 1
    private static let snapshotKeys: Set<String> = ["version", "records"]
    private static let recordKeys: Set<String> = ["identity", "key", "disposition"]
    private static let identityKeys: Set<String> = ["source", "sessionID"]
    private static let keyKeys: Set<String> = ["identity", "status", "statusChangedAt"]

    let url: URL
    private let fileManager: FileManager

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    var exists: Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func load() throws -> AttentionState {
        guard exists else {
            return AttentionState()
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AttentionStateStoreError.readFailed(error.localizedDescription)
        }

        do {
            try validateSchema(data)
            let snapshot = try Self.decoder.decode(AttentionStateSnapshot.self, from: data)
            guard snapshot.version == Self.currentVersion else {
                throw AttentionStateStoreError.unsupportedVersion(snapshot.version)
            }
            return try AttentionState(restoring: snapshot.records)
        } catch let error as AttentionStateStoreError {
            throw error
        } catch {
            throw AttentionStateStoreError.corruptData(error.localizedDescription)
        }
    }

    func save(_ state: AttentionState) throws {
        let snapshot = AttentionStateSnapshot(
            version: Self.currentVersion,
            records: state.persistedRecords
        )
        let data: Data
        do {
            data = try Self.encoder.encode(snapshot)
        } catch {
            throw AttentionStateStoreError.writeFailed(error.localizedDescription)
        }

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try writeAtomically(data)
        } catch let error as AttentionStateStoreError {
            throw error
        } catch {
            throw AttentionStateStoreError.writeFailed(error.localizedDescription)
        }
    }

    private func validateSchema(_ data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AttentionStateStoreError.corruptData(error.localizedDescription)
        }
        guard let snapshot = object as? [String: Any],
              Set(snapshot.keys) == Self.snapshotKeys,
              snapshot["version"] is NSNumber,
              let records = snapshot["records"] as? [[String: Any]] else {
            throw AttentionStateStoreError.corruptData("unexpected snapshot schema")
        }
        for record in records {
            try validateRecordSchema(record)
        }
    }

    private func validateRecordSchema(_ record: [String: Any]) throws {
        guard Set(record.keys) == Self.recordKeys,
              let identity = record["identity"] as? [String: Any],
              let key = record["key"] as? [String: Any],
              record["disposition"] is String else {
            throw AttentionStateStoreError.corruptData("unexpected record schema")
        }
        try validateIdentitySchema(identity)
        guard Set(key.keys) == Self.keyKeys,
              let keyIdentity = key["identity"] as? [String: Any],
              key["status"] is String,
              key["statusChangedAt"] is NSNumber else {
            throw AttentionStateStoreError.corruptData("unexpected attention key schema")
        }
        try validateIdentitySchema(keyIdentity)
    }

    private func validateIdentitySchema(_ identity: [String: Any]) throws {
        guard Set(identity.keys) == Self.identityKeys,
              identity["source"] is String,
              identity["sessionID"] is String else {
            throw AttentionStateStoreError.corruptData("unexpected session identity schema")
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
            throw AttentionStateStoreError.writeFailed("could not create the atomic staging file")
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
            throw AttentionStateStoreError.writeFailed(String(cString: strerror(errno)))
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

final class AttentionStateRepository {
    private let store: AttentionStateStore
    private let reconciler: AttentionReconciler
    private var state: AttentionState

    init(
        store: AttentionStateStore,
        reconciler: AttentionReconciler = AttentionReconciler()
    ) throws {
        self.store = store
        self.reconciler = reconciler
        state = try store.load()
    }

    func reconcile(
        candidates: [SessionAttentionCandidate]
    ) throws -> AttentionReconciliation {
        let result = reconciler.reconcile(candidates: candidates, state: state)
        try persistIfChanged(result.state)
        return result
    }

    func acknowledge(
        identity: SessionIdentity,
        notificationIdentifier: String? = nil
    ) throws -> AttentionAcknowledgement {
        let result = reconciler.acknowledge(
            identity: identity,
            notificationIdentifier: notificationIdentifier,
            state: state
        )
        try persistIfChanged(result.state)
        return result
    }

    private func persistIfChanged(_ updated: AttentionState) throws {
        guard updated != state else {
            return
        }
        try store.save(updated)
        state = updated
    }
}

private struct AttentionStateSnapshot: Codable {
    let version: Int
    let records: [AttentionRecord]
}
