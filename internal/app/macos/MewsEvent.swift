import Foundation

struct MewsEvent: Decodable {
    let id: String?
    let source: String
    let status: String
    let hookEvent: String?
    let agentScope: String?
    let recoverable: Bool?
    let sessionID: String?
    let project: String?
    let taskTitle: String?
    let message: String?
    let cwd: String?
    let terminal: String?
    let terminalWindowID: String?
    let kittyListenOn: String?
    let tmuxSocket: String?
    let tmuxPane: String?
    let tmuxClient: String?
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case status
        case hookEvent = "hook_event"
        case agentScope = "agent_scope"
        case recoverable
        case sessionID = "session_id"
        case project
        case taskTitle = "task_title"
        case message
        case cwd
        case terminal
        case terminalWindowID = "terminal_window_id"
        case kittyListenOn = "kitty_listen_on"
        case tmuxSocket = "tmux_socket"
        case tmuxPane = "tmux_pane"
        case tmuxClient = "tmux_client"
        case timestamp
    }

    var affectsPrimaryStatus: Bool {
        // Older events have no recoverable field and retain their original notification behavior.
        return agentScope != "subagent" && recoverable != true
    }

    var shouldNotify: Bool {
        return affectsPrimaryStatus && ["needs_input", "done", "failed"].contains(status)
    }

    var cliContext: CLIContextPayload? {
        return cliContext(cliExecutablePath: bundledCLIExecutablePath())
    }

    func cliContext(cliExecutablePath: String?) -> CLIContextPayload? {
        let command = normalizedText(sessionID).map {
            sessionReturnCommand($0, cliExecutablePath: cliExecutablePath)
        }
        return CLIContextPayload(
            returnCommand: command,
            workingDirectory: cwd,
            terminal: terminal,
            terminalWindowID: terminalWindowID,
            kittyListenOn: kittyListenOn,
            tmuxSocket: tmuxSocket,
            tmuxPane: tmuxPane,
            tmuxClient: tmuxClient
        )
    }

    func notificationUserInfo(including context: CLIContextPayload?) -> [String: String] {
        var info = context?.userInfo ?? [:]
        if let id = normalizedText(id) {
            info["event_id"] = id
        }
        if let source = normalizedText(source) {
            info["source"] = source
        }
        if let sessionID = normalizedText(sessionID) {
            info["session_id"] = sessionID
        }
        return info
    }

    var notificationTitle: String {
        return "\(sourceLabel): \(statusLabel)"
    }

    var notificationSubtitle: String {
        var parts: [String] = []
        let project = normalizedText(project)
        if let project {
            parts.append(project)
        }
        if let session = normalizedText(sessionID), session != project {
            parts.append("Session \(shortLabel(session, maximum: 8))")
        }
        return parts.joined(separator: " | ")
    }

    var notificationBody: String {
        if let taskTitle = normalizedText(taskTitle) {
            return taskTitle
        }
        switch hookEvent {
        case "PermissionRequest":
            return "Waiting for permission"
        case "Stop":
            return "Agent finished"
        case "StopFailure":
            return "Agent failed"
        case "agentStop":
            return "Agent stopped"
        case "errorOccurred":
            return "Agent reported an error"
        case "agent-turn-complete":
            return "Agent turn completed"
        default:
            break
        }
        if let message = normalizedText(message) {
            return message
        }
        switch status {
        case "needs_input":
            return "Waiting for input"
        case "done":
            return "Agent finished"
        case "failed":
            return "Agent failed"
        default:
            return "Agent status: \(status)"
        }
    }

    var summary: String {
        let project = normalizedText(project) ?? "unknown project"
        let message = normalizedText(message) ?? "no message"
        var text = "\(source) \(status) (\(project)) \(message)"
        if let session = normalizedText(sessionID) {
            text += " session \(shortLabel(session, maximum: 8))"
        }
        return text
    }

    private var sourceLabel: String {
        switch source {
        case "claude-code":
            return "Claude Code"
        case "codex":
            return "Codex"
        case "copilot":
            return "Copilot CLI"
        case "runner":
            return "Command"
        default:
            return source.isEmpty ? "Agent" : source
        }
    }

    private var statusLabel: String {
        switch status {
        case "needs_input":
            return "Needs Input"
        case "done":
            return "Done"
        case "failed":
            return "Failed"
        default:
            return status
        }
    }
}

func latestPrimaryEvent(in events: [MewsEvent]) -> MewsEvent? {
    return events.last { $0.affectsPrimaryStatus }
}

func sessionReturnCommand(_ sessionID: String, cliExecutablePath: String? = nil) -> String {
    let executable = normalizedText(cliExecutablePath).map(shellQuoteForDisplay) ?? "mw"
    return "\(executable) history --session \(shellQuoteForDisplay(sessionID))"
}

private func bundledCLIExecutablePath(bundle: Bundle = .main) -> String? {
    return bundle.path(forResource: "mw", ofType: nil)
}

private func shellQuoteForDisplay(_ value: String) -> String {
    if value.isEmpty {
        return "''"
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func shortLabel(_ value: String, maximum: Int) -> String {
    guard value.count > maximum else {
        return value
    }
    return String(value.prefix(maximum)) + "..."
}
