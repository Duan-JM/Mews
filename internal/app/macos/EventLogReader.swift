import Foundation

struct EventReload {
    let events: [MewsEvent]
    let newEvents: [MewsEvent]
    let recoveryEvents: [MewsEvent]
    let sessionResyncEvents: [MewsEvent]
    let sessionCandidateAnchor: SessionReconciliationAnchor?
    let sessionDidResync: Bool

    init(
        events: [MewsEvent],
        newEvents: [MewsEvent],
        recoveryEvents: [MewsEvent]? = nil,
        sessionResyncEvents: [MewsEvent] = [],
        sessionCandidateAnchor: SessionReconciliationAnchor? = nil,
        sessionDidResync: Bool = false
    ) {
        self.events = events
        self.newEvents = newEvents
        self.recoveryEvents = recoveryEvents ?? events
        self.sessionResyncEvents = sessionResyncEvents
        self.sessionCandidateAnchor = sessionCandidateAnchor
        self.sessionDidResync = sessionDidResync
    }
}

private struct EventNotificationAnchor: Equatable {
    let id: String?
    let source: String
    let status: String
    let hookEvent: String?
    let agentScope: String?
    let sessionID: String?
    let timestamp: Date

    init(event: MewsEvent) {
        id = event.id
        source = event.source
        status = event.status
        hookEvent = event.hookEvent
        agentScope = event.agentScope
        sessionID = event.sessionID
        timestamp = event.timestamp
    }
}

final class EventLogReader {
    private let url: URL
    private var events: [MewsEvent] = []
    private var eventOffset: UInt64 = 0
    private var eventFileNumber: UInt64?
    private var notificationAnchor: EventNotificationAnchor?
    private var eventAnchor: SessionReconciliationAnchor?
    private var didInitialEventScan = false

    init(url: URL) {
        self.url = url
    }

    func reload() throws -> EventReload {
        if !FileManager.default.fileExists(atPath: url.path) {
            resetForMissingFile()
            return EventReload(events: [], newEvents: [])
        }

        if eventFileNumber == nil {
            let scan = try EventLogFileScanner.scan(
                url: url,
                from: 0,
                anchor: nil,
                forceFull: true
            )
            return installInitial(scan: scan)
        }

        do {
            let scan = try EventLogFileScanner.scan(
                url: url,
                from: eventOffset,
                anchor: eventAnchor,
                forceFull: false
            )
            return installAppend(scan: scan)
        } catch EventLogReadError.anchorMismatch {
            let scan = try EventLogFileScanner.scan(
                url: url,
                from: 0,
                anchor: nil,
                forceFull: true
            )
            return installReplacement(scan: scan)
        }
    }

    private func resetForMissingFile() {
        events = []
        eventOffset = 0
        eventFileNumber = nil
        notificationAnchor = nil
        eventAnchor = nil
        didInitialEventScan = true
    }

    private func installInitial(scan: EventLogFileScan) -> EventReload {
        let allEvents = scan.records.map(\.event)
        events = Array(allEvents.suffix(10))
        eventOffset = scan.completeOffset
        eventFileNumber = scan.fileIdentity
        notificationAnchor = allEvents.last.map(EventNotificationAnchor.init)
        eventAnchor = scan.anchor
        let newEvents = didInitialEventScan ? allEvents : []
        didInitialEventScan = true
        return EventReload(
            events: events,
            newEvents: newEvents,
            recoveryEvents: allEvents,
            sessionResyncEvents: allEvents,
            sessionCandidateAnchor: eventAnchor,
            sessionDidResync: true
        )
    }

    private func installAppend(scan: EventLogFileScan) -> EventReload {
        let newEvents = scan.records.map(\.event)
        events.append(contentsOf: newEvents)
        events = Array(events.suffix(10))
        eventOffset = scan.completeOffset
        eventFileNumber = scan.fileIdentity
        notificationAnchor = events.last.map(EventNotificationAnchor.init)
        eventAnchor = scan.anchor
        return EventReload(
            events: events,
            newEvents: newEvents,
            sessionCandidateAnchor: eventAnchor
        )
    }

    private func installReplacement(scan: EventLogFileScan) -> EventReload {
        let allEvents = scan.records.map(\.event)
        let newEvents: [MewsEvent]
        if let notificationAnchor,
           let index = allEvents.firstIndex(where: {
               EventNotificationAnchor(event: $0) == notificationAnchor
           }) {
            newEvents = Array(allEvents.suffix(from: allEvents.index(after: index)))
        } else {
            newEvents = []
        }
        events = Array(allEvents.suffix(10))
        eventOffset = scan.completeOffset
        eventFileNumber = scan.fileIdentity
        notificationAnchor = allEvents.last.map(EventNotificationAnchor.init)
        eventAnchor = scan.anchor
        return EventReload(
            events: events,
            newEvents: newEvents,
            sessionResyncEvents: allEvents,
            sessionCandidateAnchor: eventAnchor,
            sessionDidResync: true
        )
    }
}
