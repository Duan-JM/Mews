import Foundation

struct NotchPanelContent: Equatable {
    static let empty = NotchPanelContent(
        current: nil,
        recent: [],
        actionableContext: nil
    )

    let current: NotchEventSummary?
    let recent: [NotchEventSummary]
    let actionableContext: CLIContextPayload?

    var returnCommand: String? {
        return actionableContext?.returnCommand
    }

    init(
        events: [MewsEvent],
        fileManager: FileManager = .default
    ) {
        let primaryEvents = events.filter(\.affectsPrimaryStatus)
        self.init(
            primaryEvents: primaryEvents,
            currentEvent: primaryEvents.last,
            fileManager: fileManager
        )
    }

    init(
        events: [MewsEvent],
        currentEvent: MewsEvent?,
        fileManager: FileManager = .default
    ) {
        self.init(
            primaryEvents: events.filter(\.affectsPrimaryStatus),
            currentEvent: currentEvent,
            fileManager: fileManager
        )
    }

    private init(
        current: NotchEventSummary?,
        recent: [NotchEventSummary],
        actionableContext: CLIContextPayload?
    ) {
        self.current = current
        self.recent = recent
        self.actionableContext = actionableContext
    }

    private init(
        primaryEvents: [MewsEvent],
        currentEvent: MewsEvent?,
        fileManager: FileManager
    ) {
        guard let currentEvent else {
            current = nil
            recent = primaryEvents.suffix(3).reversed().map(NotchEventSummary.init)
            actionableContext = nil
            return
        }

        current = NotchEventSummary(event: currentEvent)
        var historyEvents = primaryEvents
        if let currentIndex = historyEvents.lastIndex(where: { $0.id == currentEvent.id }) {
            historyEvents.remove(at: currentIndex)
        }
        recent = historyEvents.suffix(3).reversed().map(NotchEventSummary.init)
        actionableContext = currentEvent.cliContext?.actionable(fileManager: fileManager)
    }
}

struct NotchEventSummary: Equatable {
    let sourceLabel: String
    let statusLabel: String
    let projectLabel: String?
    let sessionLabel: String?
    let message: String
    let presentationStatus: MewsPresentationStatus

    var metadataLine: String? {
        var parts: [String] = []
        if let projectLabel {
            parts.append(projectLabel)
        }
        if let sessionLabel {
            parts.append("SESSION \(sessionLabel)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    init(event: MewsEvent) {
        sourceLabel = notchDisplayText(event.sourceLabel, maximumColumns: 18) ?? "Agent"
        statusLabel = notchDisplayText(event.statusLabel, maximumColumns: 14) ?? "Unknown"
        projectLabel = notchProjectLabel(event.project)
        sessionLabel = notchSessionLabel(event.sessionID)
        message = notchEventMessage(event)
        presentationStatus = MewsPresentationState(event: event).status
    }
}

func notchDisplayText(
    _ value: String?,
    maximumColumns: Int
) -> String? {
    guard maximumColumns > 0,
          let value,
          !value.isEmpty else {
        return nil
    }
    let sanitized = notchSanitizedOneLine(value)
    guard !sanitized.isEmpty else {
        return nil
    }
    let oneLine = notchRedactingAbsolutePaths(sanitized)
    guard !oneLine.isEmpty else {
        return nil
    }

    var result = ""
    var columns = 0
    for character in oneLine {
        let width = character.unicodeScalars.allSatisfy { $0.value < 128 } ? 1 : 2
        guard columns + width <= maximumColumns else {
            break
        }
        result.append(character)
        columns += width
    }
    return result.isEmpty ? nil : result
}

func notchDisplayColumnCount(_ value: String) -> Int {
    return value.reduce(into: 0) { columns, character in
        columns += character.unicodeScalars.allSatisfy { $0.value < 128 } ? 1 : 2
    }
}

private func notchSanitizedOneLine(_ value: String) -> String {
    let sanitized = value.map { character -> String in
        let containsControl = character.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
        return containsControl ? " " : String(character)
    }.joined()
    return sanitized.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func notchRedactingAbsolutePaths(_ value: String) -> String {
    let leadingPunctuation = CharacterSet(charactersIn: "\"'([{")
    return value.split(separator: " ").map { token in
        let candidate = String(token).trimmingCharacters(in: leadingPunctuation)
        if candidate.hasPrefix("/") ||
            candidate.hasPrefix("~/") ||
            candidate.contains("=/") {
            return "[path]"
        }
        return String(token)
    }.joined(separator: " ")
}

private func notchProjectLabel(_ value: String?) -> String? {
    guard let value,
          !value.isEmpty else {
        return nil
    }
    let oneLine = notchSanitizedOneLine(value)
    let displayValue: String
    if oneLine.hasPrefix("/") || oneLine.hasPrefix("~/") {
        displayValue = oneLine.split(separator: "/").last.map(String.init) ?? ""
    } else {
        displayValue = oneLine
    }
    return notchDisplayText(displayValue, maximumColumns: 26)
}

private func notchEventMessage(_ event: MewsEvent) -> String {
    let rawMessage: String
    if normalizedText(event.taskTitle) != nil {
        rawMessage = event.notificationBody
    } else if event.source == "runner" {
        rawMessage = runnerDisplayMessage(status: event.status)
    } else {
        rawMessage = event.notificationBody
    }
    return notchDisplayText(rawMessage, maximumColumns: 58) ?? "Status updated"
}

private func notchSessionLabel(_ value: String?) -> String? {
    guard let value = notchDisplayText(value, maximumColumns: 256) else {
        return nil
    }
    for prefix in ["session-", "thread-"] where value.lowercased().hasPrefix(prefix) {
        return notchDisplayText(String(value.dropFirst(prefix.count)), maximumColumns: 8)
    }
    return notchDisplayText(value, maximumColumns: 8)
}

private func runnerDisplayMessage(status: String) -> String {
    switch status {
    case "running":
        return "Command is running"
    case "needs_input":
        return "Command needs input"
    case "done":
        return "Command finished"
    case "failed":
        return "Command failed"
    case "idle":
        return "Command is idle"
    default:
        return "Command status changed"
    }
}
