import Foundation

struct EventReload {
    let events: [MewsEvent]
    let newEvents: [MewsEvent]
}

final class EventLogReader {
    private let url: URL
    private var events: [MewsEvent] = []
    private var eventOffset: UInt64 = 0
    private var eventFileNumber: UInt64?
    private var lastEventID: String?
    private var didInitialEventScan = false

    init(url: URL) {
        self.url = url
    }

    func reload() -> EventReload {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value else {
            resetForMissingFile()
            return EventReload(events: [], newEvents: [])
        }

        if eventFileNumber == nil {
            return loadFirstChunk(fileNumber: fileNumber)
        }
        return loadChangedFile(fileNumber: fileNumber, fileSize: fileSize)
    }

    private func resetForMissingFile() {
        events = []
        eventOffset = 0
        eventFileNumber = nil
        lastEventID = nil
        didInitialEventScan = true
    }

    private func loadFirstChunk(fileNumber: UInt64) -> EventReload {
        let chunk = readEventChunk(from: 0)
        let newEvents = didInitialEventScan ? chunk.events : []
        events = Array(chunk.events.suffix(10))
        eventOffset = chunk.offset
        eventFileNumber = fileNumber
        lastEventID = chunk.events.last?.id
        didInitialEventScan = true
        return EventReload(events: events, newEvents: newEvents)
    }

    private func loadChangedFile(fileNumber: UInt64, fileSize: UInt64) -> EventReload {
        let newEvents: [MewsEvent]
        if eventFileNumber != fileNumber || fileSize < eventOffset {
            newEvents = reloadRotatedFile()
        } else {
            newEvents = appendLatestChunk()
        }

        eventFileNumber = fileNumber
        if let newestID = events.last?.id {
            lastEventID = newestID
        }
        return EventReload(events: events, newEvents: newEvents)
    }

    private func reloadRotatedFile() -> [MewsEvent] {
        let chunk = readEventChunk(from: 0)
        let newEvents: [MewsEvent]
        if let lastEventID,
           let cursor = chunk.events.lastIndex(where: { $0.id == lastEventID }) {
            newEvents = Array(chunk.events.suffix(from: chunk.events.index(after: cursor)))
        } else {
            newEvents = []
        }
        events = Array(chunk.events.suffix(10))
        eventOffset = chunk.offset
        return newEvents
    }

    private func appendLatestChunk() -> [MewsEvent] {
        let chunk = readEventChunk(from: eventOffset)
        eventOffset = chunk.offset
        events.append(contentsOf: chunk.events)
        events = Array(events.suffix(10))
        return chunk.events
    }

    private func readEventChunk(from offset: UInt64) -> (events: [MewsEvent], offset: UInt64) {
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
        let events = content.split(separator: "\n").compactMap { line -> MewsEvent? in
            guard let data = String(line).data(using: .utf8) else {
                return nil
            }
            return try? decoder.decode(MewsEvent.self, from: data)
        }
        return (events, offset + UInt64(complete.count))
    }
}
