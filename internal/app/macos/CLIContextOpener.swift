import AppKit
import Foundation

final class CLIContextBox: NSObject {
    let payload: CLIContextPayload
    let identity: SessionIdentity?

    init(_ payload: CLIContextPayload, identity: SessionIdentity? = nil) {
        self.payload = payload
        self.identity = identity
    }
}

private enum TmuxRestoreResult {
    case notRequested
    case restored
    case opened
    case failed
}

final class CLIContextOpener {
    private let workspace: NSWorkspace
    private let pasteboard: NSPasteboard
    private let fileManager: FileManager
    private let preferenceReader: TerminalPreferenceReader
    private let log: (String) -> Void

    init(
        workspace: NSWorkspace = .shared,
        pasteboard: NSPasteboard = .general,
        fileManager: FileManager = .default,
        configURL: URL,
        log: @escaping (String) -> Void
    ) {
        self.workspace = workspace
        self.pasteboard = pasteboard
        self.fileManager = fileManager
        preferenceReader = TerminalPreferenceReader(url: configURL)
        self.log = log
    }

    func open(_ context: CLIContextPayload) {
        if let url = context.codexAppURL {
            if workspace.open(url) {
                log("Opened Codex App session")
                return
            }
            log("Could not open Codex App session; falling back to CLI context")
        }
        if let command = context.returnCommand {
            copy(command)
        }
        let preference = loadPreference()
        let requested = preference.resolved(source: context.sourceTerminalProfile)
        guard let target = resolveTarget(requested: requested, preference: preference) else {
            return
        }

        if returnToSource(
            context,
            terminalURL: target.url,
            target: target.profile,
            preference: preference
        ) {
            return
        }
        openNewContext(context, terminalURL: target.url, profile: target.profile)
    }

    func copy(_ command: String) {
        pasteboard.clearContents()
        if pasteboard.setString(command, forType: .string) {
            log("Copied return command: \(command)")
        } else {
            log("Could not copy return command")
        }
    }

    private func loadPreference() -> TerminalProfile {
        do {
            return try preferenceReader.load()
        } catch {
            log("Could not read terminal preference: \(error)")
            return .auto
        }
    }

    private func resolveTarget(
        requested: TerminalProfile,
        preference: TerminalProfile
    ) -> (profile: TerminalProfile, url: URL)? {
        if let bundleIdentifier = requested.bundleIdentifier,
           let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return (requested, url)
        }
        if preference == .auto,
           let bundleIdentifier = TerminalProfile.terminal.bundleIdentifier,
           let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            log("Could not find \(requested.displayName); using Terminal")
            return (.terminal, url)
        }
        log("Could not find configured terminal \(requested.displayName)")
        return nil
    }

    private func returnToSource(
        _ context: CLIContextPayload,
        terminalURL: URL,
        target: TerminalProfile,
        preference: TerminalProfile
    ) -> Bool {
        let sourceMatches = context.sourceTerminalProfile == target
        let explicitTmuxTarget = preference != .auto &&
            context.sourceTerminalProfile == nil &&
            context.validatedTmuxTarget(fileManager: fileManager) != nil
        guard sourceMatches || explicitTmuxTarget,
              let bundleIdentifier = target.bundleIdentifier else {
            return false
        }

        var restoredTmux = false
        switch restoreTmuxContext(context, terminalURL: terminalURL, profile: target) {
        case .notRequested:
            break
        case .restored:
            restoredTmux = true
        case .opened:
            return true
        case .failed:
            return false
        }
        if target == .kitty, restoreKitty(context) {
            log("Returned to kitty CLI context")
            return true
        }
        guard target.canActivateRunningApplication(afterTmuxRestore: restoredTmux) else {
            log("Could not restore kitty window; opening a new kitty CLI context")
            return false
        }

        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        guard applications.count == 1, let application = applications.first else {
            if applications.count > 1 {
                log("Could not identify the source \(target.displayName) instance")
            }
            return false
        }
        guard application.activate(options: [.activateAllWindows]) else {
            log("Could not activate \(target.displayName)")
            return false
        }
        log("Returned to \(target.displayName) CLI context")
        return true
    }

    private func restoreTmux(_ target: TmuxTarget, executable: URL) -> Bool {
        guard let arguments = target.switchClientArguments else {
            return false
        }
        return run(executable, arguments: arguments, action: "switch tmux client")
    }

    private func restoreKitty(_ context: CLIContextPayload) -> Bool {
        guard let target = context.validatedKittyTarget(fileManager: fileManager),
              let bundleIdentifier = TerminalProfile.kitty.bundleIdentifier,
              let appURL = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }
        let executable = appURL.appendingPathComponent("Contents/MacOS/kitty")
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            log("Could not find kitty remote-control executable")
            return false
        }
        return run(executable, arguments: target.focusArguments, action: "focus kitty window")
    }

    private func openNewContext(
        _ context: CLIContextPayload,
        terminalURL: URL,
        profile: TerminalProfile,
        launchArguments: [String] = []
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let directoryURL = context.validatedDirectoryURL(fileManager: fileManager)
        if profile == .kitty {
            var arguments = launchArguments
            if let directoryURL {
                arguments.insert(contentsOf: ["--directory", directoryURL.path], at: 0)
            }
            configuration.arguments = arguments
            configuration.createsNewApplicationInstance = true
            workspace.openApplication(
                at: terminalURL,
                configuration: configuration,
                completionHandler: completionHandler(action: "open new kitty CLI context")
            )
            return
        }
        if let directoryURL {
            workspace.open(
                [directoryURL],
                withApplicationAt: terminalURL,
                configuration: configuration,
                completionHandler: completionHandler(action: "open \(profile.displayName) CLI directory")
            )
        } else {
            workspace.openApplication(
                at: terminalURL,
                configuration: configuration,
                completionHandler: completionHandler(action: "activate \(profile.displayName)")
            )
        }
    }

    private func tmuxExecutableURL() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux"
        ]
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func run(_ executable: URL, arguments: [String], action: String) -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("Could not \(action): \(error)")
            return false
        }
        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            log("Could not \(action)\(detail.map { ": \($0)" } ?? "")")
            return false
        }
        return true
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

private extension CLIContextOpener {
    func restoreTmuxContext(
        _ context: CLIContextPayload,
        terminalURL: URL,
        profile: TerminalProfile
    ) -> TmuxRestoreResult {
        guard context.tmuxTarget != nil else {
            return .notRequested
        }
        guard let target = context.validatedTmuxTarget(fileManager: fileManager) else {
            log("Could not restore tmux context")
            return .failed
        }
        guard let executable = tmuxExecutableURL() else {
            log("Could not find tmux executable")
            return .failed
        }
        if target.clientName != nil, restoreTmux(target, executable: executable) {
            return .restored
        }
        return openDetachedTmux(
            context,
            target: target,
            executable: executable,
            terminalURL: terminalURL,
            profile: profile
        ) ? .opened : .failed
    }

    func openDetachedTmux(
        _ context: CLIContextPayload,
        target: TmuxTarget,
        executable: URL,
        terminalURL: URL,
        profile: TerminalProfile
    ) -> Bool {
        guard profile == .kitty else {
            log("Could not attach detached tmux context in \(profile.displayName)")
            return false
        }
        guard run(executable, arguments: target.verifyPaneArguments, action: "verify detached tmux target") else {
            return false
        }
        log("Opening detached tmux context in a new kitty window")
        openNewContext(
            context,
            terminalURL: terminalURL,
            profile: profile,
            launchArguments: target.attachCommandArguments(tmuxExecutablePath: executable.path)
        )
        return true
    }
}
