import Foundation

enum NotificationHealthTiming {
    static let refreshInterval: TimeInterval = 30
    static let staleAfter: TimeInterval = 90
}

struct NotificationStatusRecord: Codable, Equatable {
    let status: String
    let checkedAt: Date

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case checkedAt = "checked_at"
    }
}
