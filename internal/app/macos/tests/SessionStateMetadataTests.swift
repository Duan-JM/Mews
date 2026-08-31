import Foundation

extension MewsAppModelTests {
    static func testSessionCommandQuoting() throws {
        try sessionExpect(
            sessionReturnCommand(
                "session'1",
                cliExecutablePath: "/tmp/Mews' App/Contents/Resources/mw"
            ) ==
                "'/tmp/Mews'\\'' App/Contents/Resources/mw' history --session 'session'\\''1'",
            "session command should quote executable and session paths independently"
        )
    }

    static func testMetadataRetentionAndReplacement() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_150)
        var index = SessionStateIndex()
        let initial = try sessionEvent(
            id: "metadata-initial",
            sessionID: "metadata",
            status: "running",
            project: "Mews",
            terminal: "kitty",
            terminalWindowID: "17",
            kittyListenOn: "unix:/Users/example/initial.sock",
            timestamp: start
        )
        let omitted = try sessionEvent(
            id: "metadata-omitted",
            sessionID: "metadata",
            status: "done",
            hookEvent: "agentStop",
            timestamp: start.addingTimeInterval(1)
        )
        _ = index.apply([initial, omitted], now: omitted.timestamp)
        let current = try sessionRequire(
            index.currentSessions(now: start.addingTimeInterval(2)).first,
            "metadata session should remain readable"
        )
        try sessionExpect(current.project == "Mews", "omitted project should retain the last known project")
        try sessionExpect(
            current.returnContext?.kittyTarget?.windowID == "17",
            "omitted context should retain the last validated terminal target"
        )
        try sessionExpect(current.hookEvent == "agentStop", "hook should reflect the latest evidence")

        try applyReplacementMetadata(to: &index, start: start)
        try testPartialContextMerge()
        try testTerminalProfileChangeSanitizesTarget()
        try testCodexAppDeepLinkValidation()
        try testCodexAppContextRetention()
    }

    private static func testCodexAppDeepLinkValidation() throws {
        let codexEvent = try sessionEvent(
            id: "event-codex-app",
            source: "codex",
            sessionID: "67C4E708-30C2-4B6D-B6EF-93385DFE64AE",
            status: "done",
            project: "Mews",
            hookEvent: "Stop",
            launchContext: "codex_app",
            cwd: "/tmp",
            timestamp: Date()
        )
        let codexContext = try sessionRequire(
            codexEvent.cliContext(cliExecutablePath: "/tmp/Mews App/Contents/Resources/mw"),
            "Codex App event should have a return context"
        )
        try sessionExpect(
            codexContext.codexAppURL?.absoluteString ==
                "codex://threads/67c4e708-30c2-4b6d-b6ef-93385dfe64ae",
            "Codex App context should build the official thread deep link"
        )

        let invalidCodexContext = try sessionRequire(
            CLIContextPayload(
                returnCommand: nil,
                workingDirectory: nil,
                launchContext: "codex_app",
                codexSessionID: "not-a-thread-id"
            ),
            "the launch marker should remain available for safe fallback"
        )
        try sessionExpect(
            invalidCodexContext.codexAppURL == nil,
            "invalid Codex thread identifiers should not create app links"
        )
    }

    private static func applyReplacementMetadata(
        to index: inout SessionStateIndex,
        start: Date
    ) throws {
        let replacement = try sessionEvent(
            id: "metadata-replacement",
            sessionID: "metadata",
            status: "running",
            project: "Renamed",
            terminal: "kitty",
            terminalWindowID: "22",
            kittyListenOn: "unix:/Users/example/replacement.sock",
            timestamp: start.addingTimeInterval(3)
        )
        _ = index.apply(replacement, now: replacement.timestamp)
        let current = try sessionRequire(
            index.currentSessions(now: start.addingTimeInterval(4)).first,
            "replacement metadata should remain readable"
        )
        try sessionExpect(current.project == "Renamed", "newer non-nil project should replace prior metadata")
        try sessionExpect(
            current.returnContext?.kittyTarget?.windowID == "22",
            "newer validated context should replace the prior target"
        )
        try sessionExpect(current.hookEvent == nil, "missing latest hook should not preserve an older hook")
    }

    private static func testPartialContextMerge() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_160)
        var index = SessionStateIndex()
        let initial = try metadataEvent(
            id: "partial-initial",
            cwd: "/Users/example/original",
            terminal: "kitty",
            windowID: "31",
            kittyListen: "unix:/Users/example/partial.sock",
            timestamp: start
        )
        let cwdOnly = try metadataEvent(
            id: "partial-cwd",
            cwd: "/Users/example/new",
            timestamp: start.addingTimeInterval(1)
        )
        _ = index.apply([initial, cwdOnly], now: cwdOnly.timestamp)
        let context = try sessionRequire(
            index.currentSessions(now: cwdOnly.timestamp).first?.returnContext,
            "partially updated context should remain available"
        )

        try sessionExpect(context.workingDirectory == "/Users/example/new", "new cwd should replace prior cwd")
        try sessionExpect(context.kittyTarget?.windowID == "31", "omitted kitty target should remain available")
    }

    private static func testTerminalProfileChangeSanitizesTarget() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_170)
        var index = SessionStateIndex()
        let initial = try metadataEvent(
            id: "terminal-initial",
            cwd: "/Users/example/terminal",
            terminal: "kitty",
            windowID: "41",
            kittyListen: "unix:/Users/example/terminal.sock",
            timestamp: start
        )
        let terminalChange = try metadataEvent(
            id: "terminal-change",
            terminal: "terminal",
            timestamp: start.addingTimeInterval(1)
        )
        _ = index.apply([initial, terminalChange], now: terminalChange.timestamp)
        let context = try sessionRequire(
            index.currentSessions(now: terminalChange.timestamp).first?.returnContext,
            "terminal change should retain a validated context"
        )

        try sessionExpect(context.sourceTerminalProfile == .terminal, "new terminal profile should replace kitty")
        try sessionExpect(context.workingDirectory == "/Users/example/terminal", "omitted cwd should remain available")
        try sessionExpect(context.kittyTarget == nil, "terminal change should remove incompatible kitty metadata")
    }

    private static func testCodexAppContextRetention() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_180)
        var index = try codexAppContextIndex(start: start)
        let tmuxEvent = try sessionEvent(
            id: "codex-tmux-resume",
            source: "codex",
            sessionID: "67c4e708-30c2-4b6d-b6ef-93385dfe64ae",
            status: "running",
            hookEvent: "UserPromptSubmit",
            launchContext: "tmux",
            tmuxSocket: "/private/tmp/tmux-501/default",
            tmuxPane: "%6",
            timestamp: start.addingTimeInterval(2)
        )
        try sessionExpect(
            tmuxEvent.cliContext?.tmuxTarget?.paneID == "%6",
            "tmux fixture should decode its return target"
        )
        _ = index.apply(tmuxEvent, now: tmuxEvent.timestamp)
        let tmuxContext = try sessionRequire(
            index.currentSessions(now: tmuxEvent.timestamp).first?.returnContext,
            "resumed tmux context should remain available"
        )
        try sessionExpect(
            tmuxContext.codexAppURL == nil,
            "new tmux evidence should clear the older Codex App target"
        )
        try sessionExpect(
            tmuxContext.tmuxTarget?.paneID == "%6",
            "new tmux evidence should preserve the tmux target: \(tmuxContext.userInfo)"
        )

        try applyCodexAppAndLegacyTransitions(to: &index, start: start)
    }

    private static func codexAppContextIndex(start: Date) throws -> SessionStateIndex {
        var index = SessionStateIndex()
        let appEvent = try sessionEvent(
            id: "codex-app-start",
            source: "codex",
            sessionID: "67c4e708-30c2-4b6d-b6ef-93385dfe64ae",
            status: "running",
            hookEvent: "UserPromptSubmit",
            launchContext: "codex_app",
            timestamp: start
        )
        let laterEvent = try sessionEvent(
            id: "codex-app-stop",
            source: "codex",
            sessionID: "67c4e708-30c2-4b6d-b6ef-93385dfe64ae",
            status: "done",
            hookEvent: "Stop",
            launchContext: "codex_app",
            timestamp: start.addingTimeInterval(1)
        )
        _ = index.apply([appEvent, laterEvent], now: laterEvent.timestamp)
        let context = try sessionRequire(
            index.currentSessions(now: laterEvent.timestamp).first?.returnContext,
            "Codex App context should remain available"
        )

        try sessionExpect(
            context.codexAppURL?.absoluteString ==
                "codex://threads/67c4e708-30c2-4b6d-b6ef-93385dfe64ae",
            "later lifecycle events should retain the Codex App target"
        )
        return index
    }

    private static func applyCodexAppAndLegacyTransitions(
        to index: inout SessionStateIndex,
        start: Date
    ) throws {
        let resumedAppEvent = try sessionEvent(
            id: "codex-app-resume",
            source: "codex",
            sessionID: "67c4e708-30c2-4b6d-b6ef-93385dfe64ae",
            status: "running",
            hookEvent: "UserPromptSubmit",
            launchContext: "codex_app",
            timestamp: start.addingTimeInterval(3)
        )
        _ = index.apply(resumedAppEvent, now: resumedAppEvent.timestamp)
        let resumedAppContext = try sessionRequire(
            index.currentSessions(now: resumedAppEvent.timestamp).first?.returnContext,
            "resumed Codex App context should remain available"
        )
        try sessionExpect(
            resumedAppContext.codexAppURL?.absoluteString ==
                "codex://threads/67c4e708-30c2-4b6d-b6ef-93385dfe64ae",
            "new Codex App evidence should restore its direct target"
        )
        try sessionExpect(
            resumedAppContext.tmuxTarget == nil,
            "new Codex App evidence should clear the older tmux target"
        )

        let legacyEvent = try sessionEvent(
            id: "codex-legacy-resume",
            source: "codex",
            sessionID: "67c4e708-30c2-4b6d-b6ef-93385dfe64ae",
            status: "running",
            hookEvent: "UserPromptSubmit",
            timestamp: start.addingTimeInterval(4)
        )
        _ = index.apply(legacyEvent, now: legacyEvent.timestamp)
        let legacyContext = try sessionRequire(
            index.currentSessions(now: legacyEvent.timestamp).first?.returnContext,
            "legacy Codex context should retain a safe fallback"
        )
        try sessionExpect(
            legacyContext.launchContext == "unknown",
            "missing Codex launch evidence should be stored as unknown"
        )
        try sessionExpect(
            legacyContext.codexAppURL == nil,
            "missing Codex launch evidence should clear the older App target"
        )
    }

    private static func metadataEvent(
        id: String,
        cwd: String? = nil,
        terminal: String? = nil,
        windowID: String? = nil,
        kittyListen: String? = nil,
        timestamp: Date
    ) throws -> MewsEvent {
        return try sessionEvent(
            id: id,
            sessionID: "partial-metadata",
            status: "running",
            cwd: cwd,
            terminal: terminal,
            terminalWindowID: windowID,
            kittyListenOn: kittyListen,
            timestamp: timestamp
        )
    }
}
