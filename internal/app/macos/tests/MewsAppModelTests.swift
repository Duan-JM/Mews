import Foundation

@main
enum MewsAppModelTests {
    static func main() throws {
        try testSessionContext()
        try testSessionCommandQuoting()
        try testDirectoryValidation()
        try testTerminalPreference()
        try testTerminalMetadataValidation()
        testActionRouting()
    }

    private static func testSessionContext() throws {
        let event = MewsEvent(
            id: "event-1",
            source: "copilot",
            status: "done",
            hookEvent: "agentStop",
            sessionID: "session'1",
            project: "Mews",
            taskTitle: nil,
            message: "done",
            cwd: "/tmp",
            terminal: "kitty",
            terminalWindowID: "17",
            kittyListenOn: "unix:/tmp/kitty-control",
            tmuxSocket: "/private/tmp/tmux-501/default",
            tmuxPane: "%6",
            tmuxClient: "/dev/ttys006",
            timestamp: Date()
        )
        let cliExecutablePath = "/tmp/Mews App/Contents/Resources/mw"
        let context = try require(
            event.cliContext(cliExecutablePath: cliExecutablePath),
            "session event should have CLI context"
        )
        try expect(
            context.returnCommand ==
                "'/tmp/Mews App/Contents/Resources/mw' history --session 'session'\\''1'",
            "session command should use the shell-quoted bundled CLI path"
        )
        try expect(context.workingDirectory == "/tmp", "working directory should be preserved")
        try expect(context.sourceTerminalProfile == .kitty, "source terminal should be preserved")
        try expect(
            context.kittyTarget?.focusArguments == [
                "@",
                "--to", "unix:/tmp/kitty-control",
                "--use-password=never",
                "focus-window",
                "--match", "id:17"
            ],
            "kitty target should use fixed remote-control arguments"
        )

        let decoded = try require(
            CLIContextPayload(userInfo: event.notificationUserInfo(including: context)),
            "notification metadata should decode"
        )
        try expect(decoded == context, "notification metadata should preserve CLI context")
    }

    private static func testSessionCommandQuoting() throws {
        try expect(
            sessionReturnCommand(
                "session'1",
                cliExecutablePath: "/tmp/Mews' App/Contents/Resources/mw"
            ) ==
                "'/tmp/Mews'\\'' App/Contents/Resources/mw' history --session 'session'\\''1'",
            "return command should quote executable and session paths independently"
        )
    }

    private static func testTerminalPreference() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mews-terminal-preference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configURL = directory.appendingPathComponent("config.json")
        try Data(#"{"terminal":"kitty"}"#.utf8).write(to: configURL)
        let preference = try TerminalPreferenceReader(url: configURL).load()
        try expect(preference == .kitty, "terminal preference should decode")
        try expect(
            TerminalProfile.auto.resolved(source: .kitty) == .kitty,
            "auto should use the source terminal"
        )
        try expect(
            TerminalProfile.wezterm.bundleIdentifier == "com.github.wez.wezterm",
            "WezTerm should use its current bundle identifier"
        )
        try expect(
            !TerminalProfile.kitty.canActivateRunningApplication(afterTmuxRestore: false),
            "kitty should open a new context when exact window focus is unavailable"
        )
        try expect(
            TerminalProfile.kitty.canActivateRunningApplication(afterTmuxRestore: true),
            "kitty should activate its running application after restoring the tmux client"
        )
        try expect(
            TerminalProfile.terminal.canActivateRunningApplication(afterTmuxRestore: false),
            "Terminal can fall back to activating its running application"
        )
    }

    private static func testTerminalMetadataValidation() throws {
        let unsafe = try require(
            CLIContextPayload(
                returnCommand: "mw history",
                workingDirectory: nil,
                terminal: "kitty",
                terminalWindowID: "window-17",
                kittyListenOn: "tcp:127.0.0.1:5000",
                tmuxSocket: "relative/socket",
                tmuxPane: "6",
                tmuxClient: "/tmp/client"
            ),
            "command should keep the context actionable"
        )
        try expect(unsafe.kittyTarget == nil, "unsafe kitty metadata should be dropped")
        try expect(unsafe.tmuxSocket == nil && unsafe.tmuxPane == nil, "unsafe tmux metadata should be dropped")

        let target = TmuxTarget(
            socketPath: "/private/tmp/tmux-501/default",
            paneID: "%6",
            clientName: "/dev/ttys006"
        )
        try expect(
            target.switchClientArguments == [
                "-S", "/private/tmp/tmux-501/default",
                "switch-client", "-c", "/dev/ttys006", "-t", "%6"
            ],
            "tmux should switch the recorded client to the source session, window, and pane"
        )
    }

    private static func testDirectoryValidation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mews-cli-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let context = try require(
            CLIContextPayload(returnCommand: nil, workingDirectory: directory.path),
            "directory-only context should be retained"
        )
        try expect(context.validatedDirectoryURL() == directory.standardizedFileURL, "directory should validate")

        let relative = try require(
            CLIContextPayload(returnCommand: nil, workingDirectory: "relative/path"),
            "relative path should still decode"
        )
        try expect(relative.validatedDirectoryURL() == nil, "relative directory should not be opened")
        try expect(!relative.isActionable(), "invalid directory without a command should not be actionable")
        try expect(relative.actionable() == nil, "invalid directory should not enter notification metadata")

        try FileManager.default.removeItem(at: directory)
        try expect(
            CLIContextIntent.resolve(
                actionIdentifier: "default",
                defaultActionIdentifier: "default",
                context: context
            ) == .open,
            "an action exposed for a valid directory should retain its Terminal fallback"
        )
    }

    private static func testActionRouting() {
        let context = CLIContextPayload(returnCommand: "mw history", workingDirectory: nil)
        precondition(
            CLIContextIntent.resolve(
                actionIdentifier: "default",
                defaultActionIdentifier: "default",
                context: context
            ) == .open
        )
        precondition(
            CLIContextIntent.resolve(
                actionIdentifier: CLIContextIntent.copyActionIdentifier,
                defaultActionIdentifier: "default",
                context: context
            ) == .copy
        )
        precondition(
            CLIContextIntent.resolve(
                actionIdentifier: CLIContextIntent.openActionIdentifier,
                defaultActionIdentifier: "default",
                context: nil
            ) == .none
        )
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw TestFailure(message: message)
        }
        return value
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw TestFailure(message: message)
        }
    }
}

private struct TestFailure: Error {
    let message: String
}
