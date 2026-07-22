import Foundation

struct NotchPanelContent: Equatable {
    static let recentLimit = 3

    static let empty = NotchPanelContent(
        current: nil,
        recent: [],
        actionableContext: nil,
        actionableIdentity: nil,
        actionableEventID: nil,
        sessionRows: [],
        health: nil,
        unscopedRecent: []
    )

    let current: NotchEventSummary?
    let recent: [NotchEventSummary]
    let actionableContext: CLIContextPayload?
    let actionableIdentity: SessionIdentity?
    let actionableEventID: String?
    let sessionRows: [SessionPresentationRow]
    let health: RuntimeHealthPresentation?
    let unscopedRecent: [NotchEventSummary]

    var returnCommand: String? {
        return actionableContext?.returnCommand
    }

    var visibleSessionRows: [SessionPresentationRow] {
        return sessionRows
    }

    var visibleRecent: [NotchEventSummary] {
        guard sessionRows.isEmpty else {
            return []
        }
        return Array(recent.prefix(Self.recentLimit))
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

    init(
        presentation: SessionPresentation,
        events: [MewsEvent],
        currentEvent: MewsEvent?,
        fileManager: FileManager = .default
    ) {
        let primaryEvents = events.filter(\.affectsPrimaryStatus)
        let legacy = NotchPanelContent(
            primaryEvents: primaryEvents,
            currentEvent: currentEvent,
            fileManager: fileManager
        )
        let unscopedRecent = events
            .filter(\.affectsPrimaryStatus)
            .filter {
                SessionIdentity(source: $0.source, sessionID: $0.sessionID) == nil
            }
            .suffix(Self.recentLimit)
            .reversed()
            .map(NotchEventSummary.init)
        self.init(
            current: legacy.current,
            recent: legacy.recent,
            actionableContext: legacy.actionableContext,
            actionableIdentity: legacy.actionableIdentity,
            actionableEventID: legacy.actionableEventID,
            sessionRows: presentation.rows,
            health: presentation.health,
            unscopedRecent: unscopedRecent
        )
    }

    func stabilized(relativeTo previous: NotchPanelContent) -> NotchPanelContent {
        let retainsLegacyTarget = actionableEventID != nil &&
            actionableEventID == previous.actionableEventID
        return NotchPanelContent(
            current: previous.current,
            recent: previous.recent,
            actionableContext: retainsLegacyTarget ? actionableContext : nil,
            actionableIdentity: retainsLegacyTarget ? actionableIdentity : nil,
            actionableEventID: previous.actionableEventID,
            sessionRows: SessionPresentationPolicy.stabilizedRows(
                canonical: sessionRows,
                previous: previous.sessionRows
            ),
            health: previous.health,
            unscopedRecent: previous.unscopedRecent
        )
    }

    private init(
        current: NotchEventSummary?,
        recent: [NotchEventSummary],
        actionableContext: CLIContextPayload?,
        actionableIdentity: SessionIdentity?,
        actionableEventID: String?,
        sessionRows: [SessionPresentationRow],
        health: RuntimeHealthPresentation?,
        unscopedRecent: [NotchEventSummary]
    ) {
        self.current = current
        self.recent = recent
        self.actionableContext = actionableContext
        self.actionableIdentity = actionableIdentity
        self.actionableEventID = actionableEventID
        self.sessionRows = sessionRows
        self.health = health
        self.unscopedRecent = unscopedRecent
    }

    private init(
        primaryEvents: [MewsEvent],
        currentEvent: MewsEvent?,
        fileManager: FileManager
    ) {
        guard let currentEvent else {
            current = nil
            recent = primaryEvents
                .suffix(Self.recentLimit)
                .reversed()
                .map(NotchEventSummary.init)
            actionableContext = nil
            actionableIdentity = nil
            actionableEventID = nil
            sessionRows = []
            health = nil
            unscopedRecent = []
            return
        }

        current = NotchEventSummary(event: currentEvent)
        var historyEvents = primaryEvents
        if let currentIndex = historyEvents.lastIndex(where: { $0.id == currentEvent.id }) {
            historyEvents.remove(at: currentIndex)
        }
        recent = historyEvents
            .suffix(Self.recentLimit)
            .reversed()
            .map(NotchEventSummary.init)
        actionableContext = currentEvent.cliContext?.actionable(fileManager: fileManager)
        actionableIdentity = SessionIdentity(
            source: currentEvent.source,
            sessionID: currentEvent.sessionID
        )
        actionableEventID = currentEvent.id
        sessionRows = []
        health = nil
        unscopedRecent = []
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

func notchProjectLabel(_ value: String?) -> String? {
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

func notchSessionLabel(_ value: String?) -> String? {
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
