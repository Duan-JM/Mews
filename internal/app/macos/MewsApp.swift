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
    var events: [MewsEvent] = []
    private var started = false
    var attentionController: AttentionController?
    var attentionErrorMessage: String?
    var runtimeHealthErrorMessage: String?
    var sessionPresentationErrorMessage: String?
    private let homeURL: URL

    private lazy var eventReader = EventLogReader(url: eventsURL)
    private lazy var agentSocketProbe = AgentSocketProbe(
        path: AgentSocketPath.resolve(homeURL: homeURL)
    )
    lazy var contextOpener = CLIContextOpener(configURL: configURL) { [weak self] message in
        self?.appendAppLog(message)
    }
    lazy var notifications = NotificationManager(
        statusURL: notificationStatusURL,
        contextOpener: contextOpener,
        onAcknowledge: { [weak self] identity, notificationIdentifier in
            self?.acknowledgeAttention(
                identity: identity,
                notificationIdentifier: notificationIdentifier
            )
        },
        log: { [weak self] message in
            self?.appendAppLog(message)
        }
    )

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
        configureAttention()
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

    func reloadEvents() {
        let now = Date()
        ensureAgentRunning(at: ProcessInfo.processInfo.systemUptime)
        let reload = eventReader.reload()
        events = reload.events
        let current = currentPrimaryEvent(in: events, now: now)
        let physicalNotchAvailable = notchPanelController?.canPresentNotchAlert == true
        let attentionUpdate = reconcileAttention(reload)
        let presentationInput = sessionPresentationInput(
            attentionUpdate: attentionUpdate,
            reload: reload
        )
        let sessionPresentation = SessionPresentationPolicy.resolve(
            sessions: presentationInput.sessions,
            attentionRecords: presentationInput.attentionRecords,
            healthSnapshot: loadRuntimeHealth(),
            now: now
        )
        let notchSession = attentionUpdate.flatMap {
            currentSession(for: current, in: $0.sessions)
        }
        var announcesNotchTransition = false
        for candidate in attentionUpdate?.reconciliation.newlyAlertable ?? [] {
            switch AttentionAlertRoutingPolicy.channel(
                for: candidate,
                notchSession: notchSession,
                physicalNotchAvailable: physicalNotchAvailable
            ) {
            case .none:
                break
            case .notch:
                announcesNotchTransition = true
            case .systemNotification:
                notifications.send(for: candidate)
            }
        }
        notifications.remove(
            identifiers: attentionUpdate?.reconciliation.resolvedNotificationIdentifiers ?? []
        )
        updateStatusItem(
            now: now,
            sessionPresentation: sessionPresentation,
            announcesNotchTransition: announcesNotchTransition
        )
    }

    @objc private func reloadTimerDidFire(_ timer: Timer) {
        reloadEvents()
    }

    private func updateStatusItem(
        now: Date,
        sessionPresentation: SessionPresentation,
        announcesNotchTransition: Bool
    ) {
        let current = currentPrimaryEvent(in: events, now: now)
        let presentationState = MewsPresentationState(event: current)
        notchPanelController?.update(
            content: NotchPanelContent(
                presentation: sessionPresentation,
                events: events,
                currentEvent: current
            )
        )
        let menu = buildMenu(presentation: sessionPresentation)
        statusItemController?.update(
            state: presentationState,
            menu: menu
        )
        interactionCoordinator?.update(
            presentationState: presentationState,
            announcesTransition: announcesNotchTransition
        )
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

    var storeDirectoryURL: URL {
        return eventsURL.deletingLastPathComponent()
    }

    private var configURL: URL {
        return eventsURL
            .deletingLastPathComponent()
            .appendingPathComponent("config.json")
    }

    var logsURL: URL {
        return homeURL
            .appendingPathComponent("Library")
            .appendingPathComponent("Logs")
            .appendingPathComponent("Mews")
    }

}

extension MewsApp {
    private func startAgent(at uptime: TimeInterval) {
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
        process.environment = AgentProcessEnvironment.merging(
            ProcessInfo.processInfo.environment,
            appPath: Bundle.main.bundleURL.path
        )
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

    private func stopAgent() {
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

    private func ensureAgentRunning(at uptime: TimeInterval) {
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

    private func agentProbeDidFinish(socketResponsive: Bool) {
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

    private func configureInteractionShell() {
        let panelController = NotchPanelController(
            onOpenContext: { [weak self] context, identity in
                self?.acknowledgeAttention(identity: identity)
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
