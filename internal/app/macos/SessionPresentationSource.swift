import Foundation

struct SessionPresentationSource {
    let storeDirectory: URL
    let clock: () -> Date
    let cliExecutablePath: String?

    init(
        storeDirectory: URL,
        clock: @escaping () -> Date = Date.init,
        cliExecutablePath: String? = nil
    ) {
        self.storeDirectory = storeDirectory
        self.clock = clock
        self.cliExecutablePath = cliExecutablePath
    }

    func sessions(reconciling reload: EventReload) throws -> [CurrentSessionState] {
        let repository = try SessionStateRepository(
            store: SessionStateStore(
                url: storeDirectory.appendingPathComponent("sessions.json")
            ),
            clock: clock,
            cliExecutablePath: cliExecutablePath
        )
        _ = try repository.apply(
            EventReload(
                events: reload.events,
                newEvents: reload.newEvents,
                recoveryEvents: reload.newEvents + reload.recoveryEvents
            )
        )
        return repository.currentSessions()
    }
}
