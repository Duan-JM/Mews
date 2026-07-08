import AppKit
import Foundation

final class MewsApp: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var agent: Process?
    private var events: [MewsEvent] = []
    private var started = false

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
        events = readEvents(limit: 10)
        updateStatusItem()
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

    private func readEvents(limit: Int) -> [MewsEvent] {
        let url = eventsURL()
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        defer { try? handle.close() }

        let data = handle.readDataToEndOfFile()
        guard let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [MewsEvent] = []
        for line in content.split(separator: "\n") {
            if let data = String(line).data(using: .utf8),
               let event = try? decoder.decode(MewsEvent.self, from: data) {
                result.append(event)
                if result.count > limit {
                    result.removeFirst()
                }
            }
        }
        return result
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
    let source: String
    let status: String
    let project: String?
    let message: String?
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
