import Foundation

enum RuntimeHealthState: String, Codable {
    case checking
    case ready
    case degraded
    case blocked
}

enum RuntimeHealthKind: String, Codable {
    case configuration
    case functional
}

struct RuntimeHealthCapability: Codable, Equatable {
    let id: String
    let name: String
    let kind: RuntimeHealthKind
    let state: RuntimeHealthState
    let message: String
    let recovery: String?
    let transitionFrom: RuntimeHealthState?
    let transitionTarget: RuntimeHealthState?
    let transitionCount: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case state
        case message
        case recovery
        case transitionFrom = "transition_from"
        case transitionTarget = "transition_target"
        case transitionCount = "transition_count"
    }
}

struct RuntimeHealthSnapshot: Codable, Equatable {
    static let currentVersion = 1
    static let lifetime: TimeInterval = 30
    static let futureTolerance: TimeInterval = 5 * 60

    let version: Int
    let state: RuntimeHealthState
    let summary: String
    let checkedAt: Date
    let validUntil: Date
    let capabilities: [RuntimeHealthCapability]

    var affectedCapabilities: [RuntimeHealthCapability] {
        return capabilities.filter { $0.state != .ready }
    }

    func effectiveState(at date: Date) -> RuntimeHealthState {
        let validityWindow = validUntil.timeIntervalSince(checkedAt)
        if validityWindow < 0 ||
            validityWindow > Self.lifetime ||
            checkedAt > date.addingTimeInterval(Self.futureTolerance) ||
            date > validUntil {
            return .checking
        }
        return state
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case state
        case summary
        case checkedAt = "checked_at"
        case validUntil = "valid_until"
        case capabilities
    }
}

struct RuntimeHealthSnapshotReader {
    let url: URL

    func load() throws -> RuntimeHealthSnapshot {
        let data = try Data(contentsOf: url)
        return try RuntimeHealthSnapshotDecoder.decode(data)
    }
}

enum RuntimeHealthSnapshotDecodingError: Error, Equatable {
    case unsupportedVersion(Int)
}

enum RuntimeHealthSnapshotDecoder {
    static func decode(_ data: Data) throws -> RuntimeHealthSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try decodeRFC3339(decoder)
        }
        let snapshot = try decoder.decode(RuntimeHealthSnapshot.self, from: data)
        guard snapshot.version == RuntimeHealthSnapshot.currentVersion else {
            throw RuntimeHealthSnapshotDecodingError.unsupportedVersion(snapshot.version)
        }
        return snapshot
    }

    private static func decodeRFC3339(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]
        if let date = fractionalFormatter.date(from: value) ?? standardFormatter.date(from: value) {
            return date
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid RFC3339 timestamp: \(value)"
        )
    }
}
