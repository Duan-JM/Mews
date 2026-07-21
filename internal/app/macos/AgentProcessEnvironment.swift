import Foundation

enum AgentProcessEnvironment {
    static let appPathKey = "MEWS_APP_PATH"

    static func merging(
        _ environment: [String: String],
        appPath: String
    ) -> [String: String] {
        var merged = environment
        merged[appPathKey] = appPath
        return merged
    }
}
