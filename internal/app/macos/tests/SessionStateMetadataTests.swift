import Foundation

extension MewsAppModelTests {
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
