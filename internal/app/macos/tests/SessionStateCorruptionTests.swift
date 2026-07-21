import Foundation

extension MewsAppModelTests {
    static func testMixedInvalidContextIsCorrupt() throws {
        let directory = try sessionScratchDirectory("context-corruption")
        defer { try? FileManager.default.removeItem(at: directory) }
        let workingDirectory = directory.appendingPathComponent("working", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let store = SessionStateStore(url: directory.appendingPathComponent("sessions.json"))
        let event = try sessionEvent(
            id: "context-corruption",
            sessionID: "context-corruption",
            status: "running",
            cwd: workingDirectory.path,
            terminal: "kitty",
            terminalWindowID: "17",
            kittyListenOn: "unix:/Users/example/kitty.sock",
            timestamp: Date(timeIntervalSince1970: 1_800_000_475)
        )
        _ = try store.recover(from: [event], now: event.timestamp)
        try corruptStoredContext(at: store.url)

        do {
            _ = try store.load()
            throw SessionTestFailure(message: "mixed valid and invalid context should be rejected")
        } catch let error as SessionStateStoreError {
            guard case .corruptData = error else {
                throw SessionTestFailure(message: "invalid persisted context should report corruptData")
            }
        }
    }

    private static func corruptStoredContext(at url: URL) throws {
        let data = try Data(contentsOf: url)
        var object = try sessionRequire(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "session snapshot should decode as an object"
        )
        var sessions = try sessionRequire(
            object["sessions"] as? [[String: Any]],
            "session snapshot should contain records"
        )
        var context = try sessionRequire(
            sessions[0]["context"] as? [String: String],
            "session record should contain return context"
        )
        context[CLIContextPayload.terminalWindowIDKey] = "invalid-window"
        context[CLIContextPayload.kittyListenOnKey] = "tcp:127.0.0.1:5000"
        sessions[0]["context"] = context
        object["sessions"] = sessions
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}
