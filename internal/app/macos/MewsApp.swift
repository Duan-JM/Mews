import AppKit
import Foundation

@MainActor
final class MewsApp: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var reloadTimer: Timer?
    private var agent: Process?
    private var events: [MewsEvent] = []
    private var started = false
    private let homeURL: URL

    private lazy var eventReader = EventLogReader(url: eventsURL)
    private lazy var contextOpener = CLIContextOpener(configURL: configURL) { [weak self] message in
        self?.appendAppLog(message)
    }
    private lazy var notifications = NotificationManager(
        statusURL: notificationStatusURL,
        contextOpener: contextOpener
    ) { [weak self] message in
        self?.appendAppLog(message)
    }

    override init() {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            homeURL = URL(fileURLWithPath: home)
        } else {
            homeURL = FileManager.default.homeDirectoryForCurrentUser
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    func start() {
        guard !started else {
            return
        }
        started = true
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController()
        notifications.configure()
        startAgent()
        reloadEvents()
        let timer = Timer(
            timeInterval: 2.0,
            target: self,
            selector: #selector(reloadTimerDidFire(_:)),
            userInfo: nil,
            repeats: true
        )
        reloadTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func applicationWillTerminate(_ notification: Notification) {
        started = false
        reloadTimer?.invalidate()
        reloadTimer = nil
        statusItemController = nil
        stopAgent()
    }

    private func reloadEvents() {
        ensureAgentRunning()
        let reload = eventReader.reload()
        events = reload.events
        for event in reload.newEvents {
            notifications.send(for: event)
        }
        updateStatusItem()
    }

    @objc private func reloadTimerDidFire(_ timer: Timer) {
        reloadEvents()
    }

    private func updateStatusItem() {
        let latest = latestPrimaryEvent(in: events)
        let menu = NSMenu()
        if let latest {
            menu.addItem(eventMenuItem(for: latest))
            if let command = latest.cliContext?.returnCommand {
                menu.addItem(copyMenuItem(command: command))
            }
        } else {
            menu.addItem(NSMenuItem(title: "No events yet", action: nil, keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem.separator())
        for event in events.reversed().prefix(5) {
            menu.addItem(eventMenuItem(for: event))
        }
        if !events.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        let refresh = NSMenuItem(
            title: "Refresh",
            action: #selector(refreshClicked),
            keyEquivalent: "r"
        )
        refresh.target = self
        menu.addItem(refresh)

        let quit = NSMenuItem(
            title: "Quit Mews",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
        statusItemController?.update(
            state: MewsPresentationState(event: latest),
            menu: menu
        )
    }

    private func eventMenuItem(for event: MewsEvent) -> NSMenuItem {
        guard let context = event.cliContext, context.isActionable() else {
            return NSMenuItem(title: event.summary, action: nil, keyEquivalent: "")
        }
        let item = NSMenuItem(
            title: "\(event.summary) [return to CLI]",
            action: #selector(openCLIContextClicked(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = CLIContextBox(context)
        return item
    }

    private func copyMenuItem(command: String) -> NSMenuItem {
        let item = NSMenuItem(
            title: "Copy latest return command",
            action: #selector(copyReturnCommandClicked(_:)),
            keyEquivalent: "c"
        )
        item.target = self
        item.representedObject = command
        return item
    }

    @objc private func refreshClicked() {
        reloadEvents()
    }

    @objc private func openCLIContextClicked(_ sender: NSMenuItem) {
        guard let context = (sender.representedObject as? CLIContextBox)?.payload else {
            appendAppLog("Menu item did not contain CLI context")
            return
        }
        contextOpener.open(context)
    }

    @objc private func copyReturnCommandClicked(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else {
            appendAppLog("Menu item did not contain a return command")
            return
        }
        contextOpener.copy(command)
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
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

    private func ensureAgentRunning() {
        if let agent, agent.isRunning {
            return
        }
        agent = nil
        startAgent()
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
        return FileManager.default.isExecutableFile(atPath: fallback) ? fallback : nil
    }

    private var eventsURL: URL {
        return homeURL
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Mews")
            .appendingPathComponent("events.jsonl")
    }

    private var notificationStatusURL: URL {
        return eventsURL
            .deletingLastPathComponent()
            .appendingPathComponent("notification-status.json")
    }

    private var configURL: URL {
        return eventsURL
            .deletingLastPathComponent()
            .appendingPathComponent("config.json")
    }

    private var logsURL: URL {
        return homeURL
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")
            .appendingPathComponent("Mews")
    }

    private func logFile() -> FileHandle? {
        do {
            try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let path = logsURL.appendingPathComponent("agent.log").path
        if !FileManager.default.fileExists(atPath: path),
           !FileManager.default.createFile(atPath: path, contents: nil) {
            return nil
        }
        let handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        return handle
    }

    private func appendAppLog(_ message: String) {
        guard let handle = logFile() else {
            return
        }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data("\(Date()) \(message)\n".utf8))
    }
}

@main
@MainActor
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
