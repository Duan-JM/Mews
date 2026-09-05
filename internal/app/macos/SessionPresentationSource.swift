import Foundation

final class SessionPresentationSource {
    private let clock: () -> Date
    private let cliExecutablePath: String?
    private var index = SessionStateIndex()
    private var didReconcile = false

    init(
        clock: @escaping () -> Date = Date.init,
        cliExecutablePath: String? = nil
    ) {
        self.clock = clock
        self.cliExecutablePath = cliExecutablePath
    }

    func sessions(reconciling reload: EventReload) -> [CurrentSessionState] {
        let events: [MewsEvent]
        if reload.sessionDidResync {
            events = reload.sessionResyncEvents
        } else if didReconcile {
            events = reload.newEvents
        } else {
            events = reload.recoveryEvents
        }
        if reload.sessionDidResync {
            _ = index.rebuildOrdering(
                from: events,
                now: clock(),
                cliExecutablePath: cliExecutablePath
            )
        } else {
            _ = index.apply(
                events,
                now: clock(),
                cliExecutablePath: cliExecutablePath
            )
        }
        didReconcile = true
        return index.currentSessions(
            now: clock(),
            cliExecutablePath: cliExecutablePath
        )
    }
}
