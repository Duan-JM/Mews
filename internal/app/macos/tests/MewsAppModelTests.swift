import Foundation

@main
enum MewsAppModelTests {
    static func main() throws {
        try testSessionContext()
        try testDirectoryValidation()
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
            timestamp: Date()
        )
        let context = try require(event.cliContext, "session event should have CLI context")
        try expect(
            context.returnCommand == "mw history --session 'session'\\''1'",
            "session command should be shell quoted"
        )
        try expect(context.workingDirectory == "/tmp", "working directory should be preserved")

        let decoded = try require(
            CLIContextPayload(userInfo: event.notificationUserInfo(including: context)),
            "notification metadata should decode"
        )
        try expect(decoded == context, "notification metadata should preserve CLI context")
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
