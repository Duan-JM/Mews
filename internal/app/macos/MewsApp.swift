import AppKit
import Foundation

@MainActor
final class MewsApp: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var notchPanelController: NotchPanelController?
    private var interactionCoordinator: NotchInteractionCoordinator?
    private var reloadTimer: Timer?
    private var agent: Process?
    private var agentProcessCoordinator = AgentProcessCoordinator()
    private var agentProbeInFlight = false
    private var events: [MewsEvent] = []
    private var started = false
    private let homeURL: URL

    private lazy var eventReader = EventLogReader(url: eventsURL)
    private lazy var agentSocketProbe = AgentSocketProbe(
        path: AgentSocketPath.resolve(homeURL: homeURL)
    )
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
        guard !started else { return }
        started = true
        NSApp.setActivationPolicy(.accessory)
        configureInteractionShell()
        notifications.configure()
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
        interactionCoordinator?.stop()
        interactionCoordinator = nil
        notchPanelController = nil
        statusItemController = nil
        stopAgent()
    }

    private func reloadEvents() {
        let now = Date()
        ensureAgentRunning(at: ProcessInfo.processInfo.systemUptime)
        let reload = eventReader.reload()
        events = reload.events
        let current = currentPrimaryEvent(in: events, now: now)
        let physicalNotchAvailable = notchPanelController?.canPresentNotchAlert == true
        var announcesNotchTransition = false
        for event in reload.newEvents {
            switch EventAlertRoutingPolicy.channel(
                for: event,
                notchEvent: current,
                physicalNotchAvailable: physicalNotchAvailable
            ) {
            case .none:
                break
            case .notch:
                announcesNotchTransition = true
            case .systemNotification:
                notifications.send(for: event)
            }
        }
        updateStatusItem(
            newEvents: reload.newEvents,
            now: now,
            announcesNotchTransition: announcesNotchTransition
        )
    }

    @objc private func reloadTimerDidFire(_ timer: Timer) {
        reloadEvents()
    }

    private func updateStatusItem(
        newEvents: [MewsEvent],
        now: Date,
        announcesNotchTransition: Bool
    ) {
        let latest = latestPrimaryEvent(in: events)
        let current = currentPrimaryEvent(in: events, now: now)
        let presentationState = MewsPresentationState(event: current)
        notchPanelController?.update(
            content: NotchPanelContent(
                events: events,
                currentEvent: current
            )
        )
        let menu = buildMenu(latest: latest)
        statusItemController?.update(
            state: presentationState,
            menu: menu
        )
        let announcesTransition = announcesNotchTransition &&
            notchTransitionIsNew(latestEvent: current, newEvents: newEvents)
        interactionCoordinator?.update(
            presentationState: presentationState,
            announcesTransition: announcesTransition
        )
    }

    private func buildMenu(latest: MewsEvent?) -> NSMenu {
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
        return menu
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

private extension MewsApp {
    func startAgent(at uptime: TimeInterval) {
        guard agent == nil else {
            return
        }
        guard let helper = helperPath() else {
            appendAppLog("Could not find bundled mw helper")
            agentProcessCoordinator.recordLaunchFailure(at: uptime)
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
            agentProcessCoordinator.recordStarted(at: uptime)
        } catch {
            appendAppLog("Could not start mw agent: \(error)")
            agentProcessCoordinator.recordLaunchFailure(at: uptime)
        }
    }

    func stopAgent() {
        guard let agent else {
            agentProcessCoordinator.reset()
            return
        }
        if agent.isRunning {
            agent.terminate()
        }
        self.agent = nil
        agentProcessCoordinator.reset()
    }

    func ensureAgentRunning(at uptime: TimeInterval) {
        let childIsRunning = agent?.isRunning == true
        guard !childIsRunning else {
            return
        }
        guard !agentProbeInFlight else {
            return
        }
        let shouldProbe = agentProcessCoordinator.shouldProbeSocket(
            childIsRunning: childIsRunning,
            uptime: uptime
        )
        guard shouldProbe else {
            return
        }
        agentProbeInFlight = true
        agentSocketProbe.check { [weak self] socketResponsive in
            DispatchQueue.main.async {
                self?.agentProbeDidFinish(socketResponsive: socketResponsive)
            }
        }
    }

    func agentProbeDidFinish(socketResponsive: Bool) {
        agentProbeInFlight = false
        guard started else {
            return
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        let childIsRunning = agent?.isRunning == true
        if !childIsRunning {
            agent = nil
        }
        let action = agentProcessCoordinator.action(
            childIsRunning: childIsRunning,
            socketResponsive: socketResponsive,
            uptime: uptime
        )
        guard action == .launch else {
            return
        }
        startAgent(at: uptime)
    }

    func helperPath() -> String? {
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

    func configureInteractionShell() {
        let panelController = NotchPanelController(
            onOpenContext: { [weak self] context in
                self?.contextOpener.open(context)
            },
            onCopyCommand: { [weak self] command in
                self?.contextOpener.copy(command)
            }
        )
        notchPanelController = panelController
        let coordinator = NotchInteractionCoordinator(
            panelController: panelController,
            presentationState: MewsPresentationState(event: nil),
            statusItemFrameProvider: { [weak self] in
                self?.statusItemController?.buttonFrameOnScreen()
            },
            log: { [weak self] message in
                self?.appendAppLog(message)
            }
        )
        interactionCoordinator = coordinator
        statusItemController = StatusItemController { [weak coordinator] in
            coordinator?.logoPrimaryClicked()
        }
        coordinator.start()
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
