import Foundation

@main
@MainActor
enum MewsAppModelTests {
    static func main() throws {
        try testSessionContext()
        try testSessionCommandQuoting()
        try testDirectoryValidation()
        try testTerminalPreference()
        try testTerminalMetadataValidation()
        try testDetachedTmuxMetadataValidation()
        try testNotificationPolicy()
        try testAlertRoutingPolicy()
        try testPresentationStateMapping()
        try testPresentationPrimaryEventPolicy()
        try testPresentationFreshness()
        try testRecoverableSessionState()
        try testAgentRestartBackoff()
        try testNotificationStatusRecord()
        try testRuntimeHealthSnapshot()
        try testPixelStatusLogoPlans()
        try testNotchInteractionPolicy()
        try testNotchShellPresentation()
        try testNotchPanelContent()
        try testNotchPanelControllerTopology()
        testActionRouting()
    }

    private static func testSessionContext() throws {
        let event = MewsEvent(
            id: "event-1",
            source: "copilot",
            status: "done",
            hookEvent: "agentStop",
            agentScope: "main",
            recoverable: nil,
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

    private static func testDetachedTmuxMetadataValidation() throws {
        let detachedContext = try require(
            CLIContextPayload(
                returnCommand: "mw history",
                workingDirectory: "/tmp",
                terminal: "kitty",
                tmuxSocket: "/private/tmp/tmux-501/default",
                tmuxPane: "%6",
                tmuxClient: nil
            ),
            "detached tmux context should remain actionable"
        )
        let detachedTarget = try require(
            detachedContext.tmuxTarget,
            "detached tmux socket and pane should be preserved"
        )
        let decoded = try require(
            CLIContextPayload(userInfo: detachedContext.userInfo),
            "detached tmux notification metadata should decode"
        )
        try expect(decoded == detachedContext, "detached tmux notification metadata should round trip")
        try expect(detachedTarget.clientName == nil, "detached tmux target should not invent a client")
        try expect(
            detachedTarget.switchClientArguments == nil,
            "detached tmux target should not attempt switch-client"
        )
        try expect(
            detachedTarget.verifyPaneArguments == [
                "-S", "/private/tmp/tmux-501/default",
                "display-message", "-p", "-t", "%6", "#{pane_id}"
            ],
            "detached tmux target should be checked before launch"
        )
        try expect(
            detachedTarget.attachCommandArguments(tmuxExecutablePath: "/opt/homebrew/bin/tmux") == [
                "/usr/bin/env",
                "-u", "TMUX",
                "-u", "TMUX_PANE",
                "/opt/homebrew/bin/tmux",
                "-S", "/private/tmp/tmux-501/default",
                "attach-session",
                "-t", "%6"
            ],
            "detached tmux target should use a fixed attach command"
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

private extension MewsAppModelTests {
    static func testPresentationStateMapping() throws {
        let idle = MewsPresentationState(event: nil)
        try expect(idle.status == .idle, "missing events should present as idle")
        try expect(idle.pose == .sleeping, "idle should use the sleeping pose")
        try expect(idle.attention == .quiet, "idle should stay quiet")
        try expect(idle.motion == .none, "idle should not animate")
        try expect(idle.accessibilityLabel == "Mews is idle", "idle should have an accessibility label")

        let running = MewsPresentationState(event: try decodeEvent(agentScope: "main", status: "running"))
        try expect(running.status == .running, "running should preserve its presentation status")
        try expect(running.pose == .working, "running should use the working pose")
        try expect(running.attention == .active, "running should be active without demanding attention")
        try expect(running.motion == .workingLoop, "running should use a repeating working motion")
        try expect(running.motion.repeats, "working motion should repeat")
        try expect(
            running.effectiveMotion(reduceMotion: true) == .none,
            "Reduce Motion should disable working animation"
        )

        let needsInput = MewsPresentationState(
            event: try decodeEvent(id: "event-input", agentScope: "main", status: "needs_input")
        )
        try expect(needsInput.pose == .attention, "needs_input should use the attention pose")
        try expect(needsInput.attention == .urgent, "needs_input should be urgent")
        try expect(needsInput.motion == .attentionLoop, "needs_input should keep signaling attention")
        try expect(
            needsInput.transitionIdentifier == "event-input",
            "distinct needs_input events should retain their transition identity"
        )

        let done = MewsPresentationState(
            event: try decodeEvent(id: "event-done", agentScope: "main", status: "done")
        )
        try expect(done.pose == .success, "done should use the success pose")
        try expect(done.attention == .notice, "done should be a notice")
        try expect(done.motion == .completionOnce, "done should use a one-shot completion motion")
        try expect(done.motion.isOneShot, "completion motion should be one-shot")
        try expect(done.transitionIdentifier == "event-done", "event IDs should identify one-shot transitions")

        let failedEvent = try decodeEvent(agentScope: "main", status: "failed")
        let failed = MewsPresentationState(event: failedEvent)
        try expect(failed.pose == .failure, "failed should use the failure pose")
        try expect(failed.attention == .urgent, "failed should be urgent")
        try expect(failed.motion == .failureOnce, "failed should use a one-shot failure motion")
        try expect(failed.transitionIdentifier != nil, "legacy events should get a stable transition identifier")

        let unknown = MewsPresentationState(
            event: try decodeEvent(agentScope: "main", status: "future_status")
        )
        try expect(unknown.status == .idle, "unknown statuses should retain the existing idle fallback")
    }

    static func testPresentationPrimaryEventPolicy() throws {
        let running = try decodeEvent(agentScope: "main", status: "running")
        let subagentDone = try decodeEvent(agentScope: "subagent", status: "done")
        let recoverableFailure = try decodeEvent(
            agentScope: "main",
            status: "failed",
            recoverable: true
        )

        try expect(
            latestPresentationState(in: [running, subagentDone]).status == .running,
            "subagent events should not replace the primary presentation state"
        )
        try expect(
            latestPresentationState(in: [running, recoverableFailure]).status == .running,
            "recoverable failures should not replace the primary presentation state"
        )
    }

    static func testNotificationPolicy() throws {
        let mainCompletion = try decodeEvent(
            agentScope: "main",
            status: "done"
        )
        try expect(mainCompletion.shouldNotify, "main-agent completion should notify")

        let subagentCompletion = try decodeEvent(
            agentScope: "subagent",
            status: "done"
        )
        try expect(!subagentCompletion.shouldNotify, "subagent completion should stay silent")
        try expect(
            latestPrimaryEvent(in: [mainCompletion, subagentCompletion])?.agentScope == "main",
            "subagent events should not replace the primary menu bar state"
        )

        let recoverableError = try decodeEvent(
            agentScope: "main",
            status: "failed",
            recoverable: true
        )
        try expect(!recoverableError.shouldNotify, "recoverable errors should stay silent")

        let fatalError = try decodeEvent(
            agentScope: "main",
            status: "failed",
            recoverable: false
        )
        try expect(fatalError.shouldNotify, "non-recoverable errors should notify")
    }

    static func decodeEvent(
        id: String? = nil,
        agentScope: String,
        status: String,
        recoverable: Bool? = nil
    ) throws -> MewsEvent {
        var object: [String: Any] = [
            "source": "copilot",
            "status": status,
            "agent_scope": agentScope,
            "timestamp": "2026-07-20T12:00:00Z"
        ]
        if let id {
            object["id"] = id
        }
        if let recoverable {
            object["recoverable"] = recoverable
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MewsEvent.self, from: data)
    }
}

private struct TestFailure: Error {
    let message: String
}
