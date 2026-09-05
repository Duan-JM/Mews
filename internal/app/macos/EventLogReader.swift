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

final class EventLogReader {
    private let url: URL
    private var events: [MewsEvent] = []
    private var eventOffset: UInt64 = 0
    private var eventFileNumber: UInt64?
    private var lastEventID: String?
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
        lastEventID = nil
        eventAnchor = nil
        didInitialEventScan = true
    }

    private func installInitial(scan: EventLogFileScan) -> EventReload {
        let allEvents = scan.records.map(\.event)
        events = Array(allEvents.suffix(10))
        eventOffset = scan.completeOffset
        eventFileNumber = scan.fileIdentity
        lastEventID = allEvents.last?.id
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
        lastEventID = events.last?.id
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
        if let lastEventID,
           let index = allEvents.lastIndex(where: { $0.id == lastEventID }) {
            newEvents = Array(allEvents.suffix(from: allEvents.index(after: index)))
        } else {
            newEvents = []
        }
        events = Array(allEvents.suffix(10))
        eventOffset = scan.completeOffset
        eventFileNumber = scan.fileIdentity
        self.lastEventID = allEvents.last?.id
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
