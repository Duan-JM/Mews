import Darwin
import Foundation

struct CLIContextPayload: Equatable {
    static let returnCommandKey = "return_command"
    static let workingDirectoryKey = "cwd"
    static let terminalKey = "terminal"
    static let terminalWindowIDKey = "terminal_window_id"
    static let kittyListenOnKey = "kitty_listen_on"
    static let tmuxSocketKey = "tmux_socket"
    static let tmuxPaneKey = "tmux_pane"
    static let tmuxClientKey = "tmux_client"

    let returnCommand: String?
    let workingDirectory: String?
    let terminal: String?
    let terminalWindowID: String?
    let kittyListenOn: String?
    let tmuxSocket: String?
    let tmuxPane: String?
    let tmuxClient: String?

    init?(
        returnCommand: String?,
        workingDirectory: String?,
        terminal: String? = nil,
        terminalWindowID: String? = nil,
        kittyListenOn: String? = nil,
        tmuxSocket: String? = nil,
        tmuxPane: String? = nil,
        tmuxClient: String? = nil
    ) {
        self.returnCommand = normalizedText(returnCommand)
        self.workingDirectory = normalizedText(workingDirectory)
        self.terminal = TerminalProfile.source(terminal)?.rawValue
        self.terminalWindowID = validatedWindowID(terminalWindowID, terminal: self.terminal)
        self.kittyListenOn = validatedKittyListen(kittyListenOn, terminal: self.terminal)
        let tmux = validatedTmuxMetadata(socket: tmuxSocket, pane: tmuxPane, client: tmuxClient)
        self.tmuxSocket = tmux?.socketPath
        self.tmuxPane = tmux?.paneID
        self.tmuxClient = tmux?.clientName
        if self.returnCommand == nil && self.workingDirectory == nil && self.terminal == nil {
            return nil
        }
    }

    init?(userInfo: [AnyHashable: Any]) {
        self.init(
            returnCommand: userInfo[Self.returnCommandKey] as? String,
            workingDirectory: userInfo[Self.workingDirectoryKey] as? String,
            terminal: userInfo[Self.terminalKey] as? String,
            terminalWindowID: userInfo[Self.terminalWindowIDKey] as? String,
            kittyListenOn: userInfo[Self.kittyListenOnKey] as? String,
            tmuxSocket: userInfo[Self.tmuxSocketKey] as? String,
            tmuxPane: userInfo[Self.tmuxPaneKey] as? String,
            tmuxClient: userInfo[Self.tmuxClientKey] as? String
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
        if let terminal {
            info[Self.terminalKey] = terminal
        }
        if let terminalWindowID {
            info[Self.terminalWindowIDKey] = terminalWindowID
        }
        if let kittyListenOn {
            info[Self.kittyListenOnKey] = kittyListenOn
        }
        if let tmuxSocket {
            info[Self.tmuxSocketKey] = tmuxSocket
        }
        if let tmuxPane {
            info[Self.tmuxPaneKey] = tmuxPane
        }
        if let tmuxClient {
            info[Self.tmuxClientKey] = tmuxClient
        }
        return info
    }

    var sourceTerminalProfile: TerminalProfile? {
        return TerminalProfile.source(terminal)
    }

    var kittyTarget: KittyTarget? {
        guard let terminalWindowID, let kittyListenOn else {
            return nil
        }
        return KittyTarget(windowID: terminalWindowID, listenOn: kittyListenOn)
    }

    func validatedKittyTarget(fileManager: FileManager = .default) -> KittyTarget? {
        guard let target = kittyTarget else {
            return nil
        }
        let socketPath = String(target.listenOn.dropFirst("unix:".count))
        guard let attributes = try? fileManager.attributesOfItem(atPath: socketPath),
              attributes[.type] as? FileAttributeType == .typeSocket,
              attributes[.ownerAccountID] as? NSNumber == NSNumber(value: getuid()) else {
            return nil
        }
        return target
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
        return returnCommand != nil ||
            sourceTerminalProfile != nil ||
            validatedDirectoryURL(fileManager: fileManager) != nil
    }

    func actionable(fileManager: FileManager = .default) -> CLIContextPayload? {
        return isActionable(fileManager: fileManager) ? self : nil
    }

    var tmuxTarget: TmuxTarget? {
        guard let tmuxSocket, let tmuxPane else {
            return nil
        }
        return TmuxTarget(socketPath: tmuxSocket, paneID: tmuxPane, clientName: tmuxClient)
    }

    func validatedTmuxTarget(fileManager: FileManager = .default) -> TmuxTarget? {
        guard let target = tmuxTarget,
              let attributes = try? fileManager.attributesOfItem(atPath: target.socketPath),
              attributes[.type] as? FileAttributeType == .typeSocket,
              attributes[.ownerAccountID] as? NSNumber == NSNumber(value: getuid()) else {
            return nil
        }
        return target
    }
}

struct KittyTarget: Equatable {
    let windowID: String
    let listenOn: String

    var focusArguments: [String] {
        return [
            "@",
            "--to", listenOn,
            "--use-password=never",
            "focus-window",
            "--match", "id:\(windowID)"
        ]
    }
}

struct TmuxTarget: Equatable {
    let socketPath: String
    let paneID: String
    let clientName: String?

    var switchClientArguments: [String]? {
        guard let clientName else {
            return nil
        }
        return ["-S", socketPath, "switch-client", "-c", clientName, "-t", paneID]
    }

    var verifyPaneArguments: [String] {
        return ["-S", socketPath, "display-message", "-p", "-t", paneID, "#{pane_id}"]
    }

    func attachCommandArguments(tmuxExecutablePath: String) -> [String] {
        return [
            "/usr/bin/env",
            "-u", "TMUX",
            "-u", "TMUX_PANE",
            tmuxExecutablePath,
            "-S", socketPath,
            "attach-session",
            "-t", paneID
        ]
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

    var acknowledgesAttention: Bool {
        return self == .open
    }
}

func normalizedText(_ value: String?) -> String? {
    guard let value else {
        return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func validatedWindowID(_ value: String?, terminal: String?) -> String? {
    guard terminal == TerminalProfile.kitty.rawValue,
          let value = normalizedText(value),
          value.count <= 64,
          asciiDigitsOnly(value) else {
        return nil
    }
    return value
}

private func validatedKittyListen(_ value: String?, terminal: String?) -> String? {
    guard terminal == TerminalProfile.kitty.rawValue,
          let value = normalizedText(value),
          value.count <= 4096,
          value.hasPrefix("unix:/") else {
        return nil
    }
    return value
}

private func validatedTmuxMetadata(
    socket: String?,
    pane: String?,
    client: String?
) -> TmuxTarget? {
    guard let socket = normalizedText(socket),
          socket.hasPrefix("/"),
          socket.count <= 4096,
          let pane = normalizedText(pane),
          pane.count <= 64,
          pane.first == "%",
          asciiDigitsOnly(String(pane.dropFirst())),
          pane.count > 1 else {
        return nil
    }
    let client = normalizedText(client)
    if let client {
        guard client.hasPrefix("/dev/"),
              client.count <= 4096,
              !client.contains("\0"),
              !client.contains("\r"),
              !client.contains("\n"),
              URL(fileURLWithPath: client).standardizedFileURL.path == client else {
            return nil
        }
    }
    return TmuxTarget(socketPath: socket, paneID: pane, clientName: client)
}

private func asciiDigitsOnly(_ value: String) -> Bool {
    return !value.isEmpty && value.unicodeScalars.allSatisfy {
        $0.value >= 48 && $0.value <= 57
    }
}
