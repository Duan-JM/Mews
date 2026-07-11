import AppKit
import Foundation
import UserNotifications

final class MewsApp: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
        statusItem.button?.title = "Mews"
        configureNotifications()
        startAgent()
        reloadEvents()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.reloadEvents()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
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

    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            center.getNotificationSettings { settings in
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
        content.title = "Mews"
        content.body = event.message?.isEmpty == false
            ? event.message!
            : "\(event.source): \(event.status)"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.appendAppLog("Could not deliver notification: \(error)")
            }
        }
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
        statusItem.button?.title = title(for: latest)

        let menu = NSMenu()
        if let latest {
            menu.addItem(NSMenuItem(title: summary(for: latest), action: nil, keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "No events yet", action: nil, keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem.separator())
        for event in events.reversed().prefix(5) {
            menu.addItem(NSMenuItem(title: summary(for: event), action: nil, keyEquivalent: ""))
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
        statusItem.menu = menu
    }

    @objc private func refreshClicked() {
        reloadEvents()
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
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
        return "\(event.source) \(event.status) (\(project)) \(message)"
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
    let project: String?
    let message: String?
    let timestamp: Date
}

@main
enum Main {
    private static var delegate: MewsApp?

    static func main() {
        let app = NSApplication.shared
        let delegate = MewsApp()
        Self.delegate = delegate
        app.delegate = delegate
        delegate.start()
        app.run()
    }
}
