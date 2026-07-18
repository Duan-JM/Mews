import AppKit
import Foundation

final class CLIContextBox: NSObject {
    let payload: CLIContextPayload

    init(_ payload: CLIContextPayload) {
        self.payload = payload
    }
}

final class CLIContextOpener {
    private let workspace: NSWorkspace
    private let pasteboard: NSPasteboard
    private let fileManager: FileManager
    private let log: (String) -> Void

    init(
        workspace: NSWorkspace = .shared,
        pasteboard: NSPasteboard = .general,
        fileManager: FileManager = .default,
        log: @escaping (String) -> Void
    ) {
        self.workspace = workspace
        self.pasteboard = pasteboard
        self.fileManager = fileManager
        self.log = log
    }

    func open(_ context: CLIContextPayload) {
        if let command = context.returnCommand {
            copy(command)
        }
        guard let terminalURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            log("Could not find Terminal.app")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let directoryURL = context.validatedDirectoryURL(fileManager: fileManager) {
            workspace.open(
                [directoryURL],
                withApplicationAt: terminalURL,
                configuration: configuration,
                completionHandler: completionHandler(action: "open CLI directory")
            )
        } else {
            workspace.openApplication(
                at: terminalURL,
                configuration: configuration,
                completionHandler: completionHandler(action: "activate Terminal")
            )
        }
    }

    func copy(_ command: String) {
        pasteboard.clearContents()
        if pasteboard.setString(command, forType: .string) {
            log("Copied return command: \(command)")
        } else {
            log("Could not copy return command")
        }
    }

    private func completionHandler(
        action: String
    ) -> (NSRunningApplication?, (any Error)?) -> Void {
        return { [log] _, error in
            if let error {
                log("Could not \(action): \(error)")
            }
        }
    }
}
