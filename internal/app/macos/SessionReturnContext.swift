import Foundation

struct SessionReturnContext: Codable, Equatable {
    private let values: [String: String]

    init?(payload: CLIContextPayload?) {
        guard let payload else {
            return nil
        }
        var metadata = payload.userInfo
        metadata.removeValue(forKey: CLIContextPayload.returnCommandKey)
        guard !metadata.isEmpty else {
            return nil
        }
        values = metadata
    }

    init(from decoder: Decoder) throws {
        let values = try [String: String](from: decoder)
        guard values[CLIContextPayload.returnCommandKey] == nil else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "session return context contains a forbidden command"
                )
            )
        }
        guard let payload = Self.payload(from: values) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "session return context is empty"
                )
            )
        }
        var metadata = payload.userInfo
        metadata.removeValue(forKey: CLIContextPayload.returnCommandKey)
        guard !metadata.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "session return context has no validated metadata"
                )
            )
        }
        guard metadata == values else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "session return context contains unknown or invalid metadata"
                )
            )
        }
        self.values = values
    }

    func encode(to encoder: Encoder) throws {
        try values.encode(to: encoder)
    }

    static func merging(
        prior: SessionReturnContext?,
        newer: SessionReturnContext?
    ) -> SessionReturnContext? {
        guard let prior else {
            return newer
        }
        guard let newer else {
            return prior
        }

        var merged = prior.values
        merged.merge(newer.values) { _, newValue in newValue }
        return SessionReturnContext(payload: payload(from: merged))
    }

    static func payload(
        metadata: SessionReturnContext?,
        sessionID: String,
        cliExecutablePath: String?
    ) -> CLIContextPayload? {
        var values = metadata?.values ?? [:]
        values[CLIContextPayload.returnCommandKey] = sessionReturnCommand(
            sessionID,
            cliExecutablePath: cliExecutablePath
        )
        return payload(from: values)
    }

    private static func payload(from values: [String: String]) -> CLIContextPayload? {
        let userInfo = values.reduce(into: [AnyHashable: Any]()) { result, item in
            result[item.key] = item.value
        }
        return CLIContextPayload(userInfo: userInfo)
    }
}
