import AppKit
import Foundation
import UserNotifications

final class MewsApp: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var agent: Process?
    private var events: [MewsEvent] = []
    private var started = false
    private var eventOffset: UInt64 = 0
    private var eventFileNumber: UInt64?
    private var lastEventID: String?
    private var didInitialEventScan = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    func start() {
        guard !started else {
            return
        }
        started = true
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "Mews"
        if let image = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "Mews") {
            image.isTemplate = true
            statusItem?.button?.image = image
            statusItem?.button?.imagePosition = .imageLeading
        }
        configureNotifications()
        startAgent()
        reloadEvents()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.reloadEvents()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        started = false
        timer?.invalidate()
        timer = nil
        stopAgent()
    }

    private func startAgent() {
        guard agent == nil else {
            return
        }
        guard let helper = helperPath() else {
            appendAppLog("Could not find bundled mw helper")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["agent"]
        let log = logFile()
        process.standardOutput = log
        process.standardError = log

        do {
            try process.run()
            agent = process
        } catch {
            appendAppLog("Could not start mw agent: \(error)")
        }
    }

    private func stopAgent() {
        guard let agent else {
            return
        }
        if agent.isRunning {
            agent.terminate()
        }
        self.agent = nil
    }

    private func helperPath() -> String? {
        if let helper = Bundle.main.path(forResource: "mw", ofType: nil) {
            return helper
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let fallback = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .appendingPathComponent("mw")
            .path
        if FileManager.default.isExecutableFile(atPath: fallback) {
            return fallback
        }
        return nil
    }

    private func reloadEvents() {
        ensureAgentRunning()
        let url = eventsURL()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value else {
            events = []
            eventOffset = 0
            eventFileNumber = nil
            lastEventID = nil
            didInitialEventScan = true
            updateStatusItem()
            return
        }

        if eventFileNumber == nil {
            let chunk = readEventChunk(from: 0)
            let shouldNotify = didInitialEventScan
            events = Array(chunk.events.suffix(10))
            eventOffset = chunk.offset
            eventFileNumber = fileNumber
            lastEventID = chunk.events.last?.id
            didInitialEventScan = true
            if shouldNotify {
                for event in chunk.events {
                    sendNotification(for: event)
                }
            }
            updateStatusItem()
            return
        }

        var newEvents: [MewsEvent]
        if eventFileNumber != fileNumber || fileSize < eventOffset {
            let chunk = readEventChunk(from: 0)
            if let lastEventID,
               let cursor = chunk.events.lastIndex(where: { $0.id == lastEventID }) {
                newEvents = Array(chunk.events.suffix(from: chunk.events.index(after: cursor)))
            } else {
                newEvents = []
            }
            events = Array(chunk.events.suffix(10))
            eventOffset = chunk.offset
        } else {
            let chunk = readEventChunk(from: eventOffset)
            newEvents = chunk.events
            eventOffset = chunk.offset
            events.append(contentsOf: newEvents)
            events = Array(events.suffix(10))
        }

        for event in newEvents {
            sendNotification(for: event)
        }
        eventFileNumber = fileNumber
        if let newestID = events.last?.id {
            lastEventID = newestID
        }
        updateStatusItem()
    }

    private func ensureAgentRunning() {
        if let agent, agent.isRunning {
            return
        }
        agent = nil
        startAgent()
    }

    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            if let error {
                self?.appendAppLog("Could not request notification permission: \(error)")
            }
            center.getNotificationSettings { settings in
                self?.appendAppLog(
                    "Notification settings authorization=\(settings.authorizationStatus.rawValue) " +
                    "alert=\(settings.alertSetting.rawValue) center=\(settings.notificationCenterSetting.rawValue)"
                )
                self?.writeNotificationStatus(settings.authorizationStatus)
            }
        }
    }

    private func sendNotification(for event: MewsEvent) {
        guard ["needs_input", "done", "failed"].contains(event.status) else {
            return
        }
        appendAppLog("Notification queued for event \(event.id ?? "unknown")")
        let content = UNMutableNotificationContent()
        content.title = notificationTitle(for: event)
        content.subtitle = notificationSubtitle(for: event)
        content.body = notificationBody(for: event)
        content.sound = .default
        content.userInfo = notificationUserInfo(for: event)
        let request = UNNotificationRequest(
            identifier: event.id ?? UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.appendAppLog("Could not deliver notification: \(error)")
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let command = response.notification.request.content.userInfo["return_command"] as? String {
            copyToPasteboard(command)
            appendAppLog("Copied return command from notification: \(command)")
        }
        completionHandler()
    }

    private func notificationUserInfo(for event: MewsEvent) -> [String: String] {
        var info: [String: String] = [:]
        if let id = nonEmpty(event.id) {
            info["event_id"] = id
        }
        if let source = nonEmpty(event.source) {
            info["source"] = source
        }
        if let session = nonEmpty(event.sessionID) {
            info["session_id"] = session
            info["return_command"] = sessionReturnCommand(session)
        }
        return info
    }

    private func notificationTitle(for event: MewsEvent) -> String {
        return "\(sourceLabel(event.source)): \(statusLabel(event.status))"
    }

    private func notificationSubtitle(for event: MewsEvent) -> String {
        var parts: [String] = []
        let project = nonEmpty(event.project)
        if let project {
            parts.append(project)
        }
        if let session = nonEmpty(event.sessionID), session != project {
            parts.append("Session \(shortLabel(session, max: 8))")
        }
        return parts.joined(separator: " | ")
    }

    private func notificationBody(for event: MewsEvent) -> String {
        if let taskTitle = nonEmpty(event.taskTitle) {
            return taskTitle
        }
        switch event.hookEvent {
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
        if let message = nonEmpty(event.message) {
            return message
        }
        switch event.status {
        case "needs_input":
            return "Waiting for input"
        case "done":
            return "Agent finished"
        case "failed":
            return "Agent failed"
        default:
            return "Agent status: \(event.status)"
        }
    }

    private func sourceLabel(_ source: String) -> String {
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

    private func statusLabel(_ status: String) -> String {
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

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func shortLabel(_ value: String, max: Int) -> String {
        guard value.count > max else {
            return value
        }
        return String(value.prefix(max)) + "..."
    }

    private func writeNotificationStatus(_ status: UNAuthorizationStatus) {
        let value: String
        switch status {
        case .authorized, .provisional, .ephemeral:
            value = "authorized"
        case .denied:
            value = "denied"
        case .notDetermined:
            value = "not_determined"
        @unknown default:
            value = "unknown"
        }
        let data = try? JSONSerialization.data(
            withJSONObject: ["status": value],
            options: [.prettyPrinted, .sortedKeys]
        )
        guard let data else {
            return
        }
        let directory = eventsURL().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(
            to: directory.appendingPathComponent("notification-status.json"),
            options: .atomic
        )
    }

    private func updateStatusItem() {
        let latest = events.last
        statusItem?.button?.title = title(for: latest)

        let menu = NSMenu()
        if let latest {
            menu.addItem(eventMenuItem(for: latest, title: summary(for: latest)))
            if let command = returnCommand(for: latest) {
                let copy = NSMenuItem(title: "Copy latest return command", action: #selector(copyReturnCommandClicked(_:)), keyEquivalent: "c")
                copy.target = self
                copy.representedObject = command
                menu.addItem(copy)
            }
        } else {
            menu.addItem(NSMenuItem(title: "No events yet", action: nil, keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem.separator())
        for event in events.reversed().prefix(5) {
            menu.addItem(eventMenuItem(for: event, title: summary(for: event)))
        }
        if !events.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshClicked), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let quit = NSMenuItem(title: "Quit Mews", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
    }

    @objc private func refreshClicked() {
        reloadEvents()
    }

    @objc private func copyReturnCommandClicked(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else {
            return
        }
        copyToPasteboard(command)
        appendAppLog("Copied return command from menu: \(command)")
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    private func eventMenuItem(for event: MewsEvent, title: String) -> NSMenuItem {
        guard let command = returnCommand(for: event) else {
            return NSMenuItem(title: title, action: nil, keyEquivalent: "")
        }
        let item = NSMenuItem(title: "\(title) [copy return]", action: #selector(copyReturnCommandClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command
        return item
    }

    private func title(for event: MewsEvent?) -> String {
        guard let event else {
            return "Mews"
        }
        switch event.status {
        case "running":
            return "Mews Running"
        case "needs_input":
            return "Mews Needs Input"
        case "done":
            return "Mews Done"
        case "failed":
            return "Mews Failed"
        default:
            return "Mews Idle"
        }
    }

    private func summary(for event: MewsEvent) -> String {
        let project = event.project?.isEmpty == false ? event.project! : "unknown project"
        let message = event.message?.isEmpty == false ? event.message! : "no message"
        var text = "\(event.source) \(event.status) (\(project)) \(message)"
        if let session = nonEmpty(event.sessionID) {
            text += " session \(shortLabel(session, max: 8))"
        }
        return text
    }

    private func returnCommand(for event: MewsEvent) -> String? {
        guard let session = nonEmpty(event.sessionID) else {
            return nil
        }
        return sessionReturnCommand(session)
    }

    private func sessionReturnCommand(_ sessionID: String) -> String {
        return "mw history --session \(shellQuoteForDisplay(sessionID))"
    }

    private func shellQuoteForDisplay(_ value: String) -> String {
        if value.isEmpty {
            return "''"
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func readEventChunk(from offset: UInt64) -> (events: [MewsEvent], offset: UInt64) {
        let url = eventsURL()
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ([], offset)
        }
        defer { try? handle.close() }

        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard let newline = data.lastIndex(of: 0x0A) else {
            return ([], offset)
        }
        let complete = data.prefix(through: newline)
        guard let content = String(data: complete, encoding: .utf8) else {
            return ([], offset)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [MewsEvent] = []
        for line in content.split(separator: "\n") {
            if let data = String(line).data(using: .utf8),
               let event = try? decoder.decode(MewsEvent.self, from: data) {
                result.append(event)
            }
        }
        return (result, offset + UInt64(complete.count))
    }

    private func eventsURL() -> URL {
        return homeURL()
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Mews")
            .appendingPathComponent("events.jsonl")
    }

    private func logFile() -> FileHandle? {
        let logs = homeURL()
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")
            .appendingPathComponent("Mews")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let path = logs.appendingPathComponent("agent.log").path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        return handle
    }

    private func homeURL() -> URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func appendAppLog(_ message: String) {
        guard let handle = logFile() else {
            return
        }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        if let data = "\(Date()) \(message)\n".data(using: .utf8) {
            handle.write(data)
        }
    }
}

struct MewsEvent: Decodable {
    let id: String?
    let source: String
    let status: String
    let hookEvent: String?
    let sessionID: String?
    let project: String?
    let taskTitle: String?
    let message: String?
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case status
        case hookEvent = "hook_event"
        case sessionID = "session_id"
        case project
        case taskTitle = "task_title"
        case message
        case timestamp
    }
}

@main
enum Main {
    private static var delegate: MewsApp?

    static func main() {
        let app = NSApplication.shared
        let delegate = MewsApp()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}
