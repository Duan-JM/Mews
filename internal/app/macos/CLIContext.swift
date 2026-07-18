import Foundation

struct CLIContextPayload: Equatable {
    static let returnCommandKey = "return_command"
    static let workingDirectoryKey = "cwd"

    let returnCommand: String?
    let workingDirectory: String?

    init?(returnCommand: String?, workingDirectory: String?) {
        self.returnCommand = normalizedText(returnCommand)
        self.workingDirectory = normalizedText(workingDirectory)
        if self.returnCommand == nil && self.workingDirectory == nil {
            return nil
        }
    }

    init?(userInfo: [AnyHashable: Any]) {
        self.init(
            returnCommand: userInfo[Self.returnCommandKey] as? String,
            workingDirectory: userInfo[Self.workingDirectoryKey] as? String
        )
    }

    var userInfo: [String: String] {
        var info: [String: String] = [:]
        if let returnCommand {
            info[Self.returnCommandKey] = returnCommand
        }
        if let workingDirectory {
            info[Self.workingDirectoryKey] = workingDirectory
        }
        return info
    }

    func validatedDirectoryURL(fileManager: FileManager = .default) -> URL? {
        guard let workingDirectory, workingDirectory.hasPrefix("/") else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: workingDirectory, isDirectory: true).standardizedFileURL
    }

    func isActionable(fileManager: FileManager = .default) -> Bool {
        return returnCommand != nil || validatedDirectoryURL(fileManager: fileManager) != nil
    }

    func actionable(fileManager: FileManager = .default) -> CLIContextPayload? {
        return isActionable(fileManager: fileManager) ? self : nil
    }
}

enum CLIContextIntent: Equatable {
    case open
    case copy
    case none

    static let openActionIdentifier = "dev.mews.open-cli-context"
    static let copyActionIdentifier = "dev.mews.copy-return-command"

    static func resolve(
        actionIdentifier: String,
        defaultActionIdentifier: String,
        context: CLIContextPayload?
    ) -> CLIContextIntent {
        guard let context else {
            return .none
        }
        if actionIdentifier == openActionIdentifier || actionIdentifier == defaultActionIdentifier {
            return .open
        }
        if actionIdentifier == copyActionIdentifier, context.returnCommand != nil {
            return .copy
        }
        return .none
    }
}

func normalizedText(_ value: String?) -> String? {
    guard let value else {
        return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
