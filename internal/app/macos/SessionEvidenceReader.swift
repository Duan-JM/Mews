import Darwin
import Foundation

struct EventLogFileMetadata: Equatable {
    let size: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
}

struct SessionReconciliationAnchor: Equatable {
    let fileIdentity: UInt64
    let offset: UInt64
    let lastEventID: String?
    let lineDigest: String?
    let lineStartOffset: UInt64?
    let fileMetadata: EventLogFileMetadata?
    let prefixDigest: String?

    init(
        fileIdentity: UInt64,
        offset: UInt64,
        lastEventID: String?,
        lineDigest: String?,
        lineStartOffset: UInt64? = nil,
        fileMetadata: EventLogFileMetadata? = nil,
        prefixDigest: String? = nil
    ) {
        self.fileIdentity = fileIdentity
        self.offset = offset
        self.lastEventID = lastEventID
        self.lineDigest = lineDigest
        self.lineStartOffset = lineStartOffset
        self.fileMetadata = fileMetadata
        self.prefixDigest = prefixDigest
    }
}

struct SessionEvidenceScan {
    let events: [MewsEvent]
    let candidateAnchor: SessionReconciliationAnchor?
    let didResync: Bool
}

enum EventLogReadError: Error, Equatable {
    case missingFile
    case openFailed(String)
    case statFailed(String)
    case readFailed(String)
    case malformedLine(UInt64)
    case unstableFile
    case anchorMismatch
    case boundaryMismatch
}

struct EventLogRecord {
    let event: MewsEvent
    let startOffset: UInt64
    let digest: String
}

struct EventLogFileScan {
    let records: [EventLogRecord]
    let completeOffset: UInt64
    let anchor: SessionReconciliationAnchor?
    let fileIdentity: UInt64
    let didResync: Bool
}

private struct EventLogScanStart {
    let fileStatus: stat
    let fileIdentity: UInt64
    let fileMetadata: EventLogFileMetadata
    let readOffset: UInt64
    let readLimit: UInt64?
}

enum EventLogFileScanner {
    static func scan(
        url: URL,
        from offset: UInt64,
        anchor: SessionReconciliationAnchor?,
        through boundary: SessionReconciliationAnchor? = nil,
        forceFull: Bool = false
    ) throws -> EventLogFileScan {
        for _ in 0..<3 {
            do {
                return try scanOnce(
                    url: url,
                    from: offset,
                    anchor: anchor,
                    through: boundary,
                    forceFull: forceFull
                )
            } catch EventLogReadError.unstableFile {
                continue
            }
        }
        throw EventLogReadError.unstableFile
    }

    private static func scanOnce(
        url: URL,
        from offset: UInt64,
        anchor: SessionReconciliationAnchor?,
        through boundary: SessionReconciliationAnchor?,
        forceFull: Bool
    ) throws -> EventLogFileScan {
        let descriptor = try EventLogFileIO.openDescriptor(url)
        defer { close(descriptor) }

        let start = try scanStart(
            descriptor: descriptor,
            offset: offset,
            anchor: anchor,
            through: boundary,
            forceFull: forceFull
        )
        let complete = try completeData(
            descriptor: descriptor,
            scanStart: start,
            through: boundary
        )
        let records = try decodeRecords(complete, baseOffset: start.readOffset)
        let completeOffset = start.readOffset + UInt64(complete.count)
        let prefixDigest = try EventLogFileIO.candidatePrefixDigest(
            prior: forceFull ? nil : anchor,
            complete: complete,
            completeOffset: completeOffset,
            descriptor: descriptor
        )
        try EventLogFileIO.validateStableFile(
            descriptor: descriptor,
            url: url,
            initialStatus: start.fileStatus,
            initialMetadata: start.fileMetadata
        )
        return EventLogFileScan(
            records: records,
            completeOffset: completeOffset,
            anchor: boundary ?? candidateAnchor(
                records: records,
                prior: forceFull ? nil : anchor,
                scanStart: start,
                completeOffset: completeOffset,
                prefixDigest: prefixDigest
            ),
            fileIdentity: start.fileIdentity,
            didResync: forceFull
        )
    }

    private static func completeData(
        descriptor: Int32,
        scanStart: EventLogScanStart,
        through boundary: SessionReconciliationAnchor?
    ) throws -> Data {
        let data: Data
        do {
            data = try EventLogFileIO.readData(
                descriptor: descriptor,
                from: scanStart.readOffset,
                through: scanStart.readLimit
            )
        } catch EventLogReadError.anchorMismatch where boundary != nil {
            throw EventLogReadError.boundaryMismatch
        }
        guard let newline = data.lastIndex(of: 0x0A) else {
            if boundary != nil, !data.isEmpty {
                throw EventLogReadError.boundaryMismatch
            }
            return Data()
        }
        let complete = Data(data.prefix(through: newline))
        if boundary != nil, complete.count != data.count {
            throw EventLogReadError.boundaryMismatch
        }
        return complete
    }

    private static func scanStart(
        descriptor: Int32,
        offset: UInt64,
        anchor: SessionReconciliationAnchor?,
        through boundary: SessionReconciliationAnchor?,
        forceFull: Bool
    ) throws -> EventLogScanStart {
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0 else {
            throw EventLogReadError.statFailed(String(cString: strerror(errno)))
        }
        let fileIdentity = EventLogFileIO.identity(of: fileStatus)
        let fileMetadata = EventLogFileIO.metadata(of: fileStatus)
        let readOffset = forceFull ? 0 : offset
        try validateBoundary(
            boundary,
            fileIdentity: fileIdentity,
            fileMetadata: fileMetadata,
            readOffset: readOffset,
            descriptor: descriptor
        )
        guard !forceFull else {
            return EventLogScanStart(
                fileStatus: fileStatus,
                fileIdentity: fileIdentity,
                fileMetadata: fileMetadata,
                readOffset: 0,
                readLimit: boundary?.offset
            )
        }
        guard let anchor,
              anchor.fileIdentity == fileIdentity,
              fileMetadata.size >= offset else {
            throw EventLogReadError.anchorMismatch
        }
        if anchor.fileMetadata != fileMetadata {
            try EventLogFileIO.validate(anchor: anchor, descriptor: descriptor)
        }
        return EventLogScanStart(
            fileStatus: fileStatus,
            fileIdentity: fileIdentity,
            fileMetadata: fileMetadata,
            readOffset: offset,
            readLimit: boundary?.offset
        )
    }

    private static func validateBoundary(
        _ boundary: SessionReconciliationAnchor?,
        fileIdentity: UInt64,
        fileMetadata: EventLogFileMetadata,
        readOffset: UInt64,
        descriptor: Int32
    ) throws {
        guard let boundary else {
            return
        }
        guard boundary.fileIdentity == fileIdentity,
              boundary.offset >= readOffset,
              boundary.offset <= fileMetadata.size else {
            throw EventLogReadError.boundaryMismatch
        }
        guard boundary.fileMetadata != fileMetadata else {
            return
        }
        do {
            try EventLogFileIO.validate(anchor: boundary, descriptor: descriptor)
        } catch EventLogReadError.anchorMismatch {
            throw EventLogReadError.boundaryMismatch
        }
    }

    private static func candidateAnchor(
        records: [EventLogRecord],
        prior: SessionReconciliationAnchor?,
        scanStart: EventLogScanStart,
        completeOffset: UInt64,
        prefixDigest: String
    ) -> SessionReconciliationAnchor {
        guard let last = records.last else {
            return prior ?? SessionReconciliationAnchor(
                fileIdentity: scanStart.fileIdentity,
                offset: completeOffset,
                lastEventID: nil,
                lineDigest: nil,
                fileMetadata: scanStart.fileMetadata,
                prefixDigest: prefixDigest
            )
        }
        return SessionReconciliationAnchor(
            fileIdentity: scanStart.fileIdentity,
            offset: completeOffset,
            lastEventID: last.event.id,
            lineDigest: last.digest,
            lineStartOffset: last.startOffset,
            fileMetadata: scanStart.fileMetadata,
            prefixDigest: prefixDigest
        )
    }

    private static func decodeRecords(
        _ data: Data,
        baseOffset: UInt64
    ) throws -> [EventLogRecord] {
        var records: [EventLogRecord] = []
        var lineStart = baseOffset
        for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let lineLength = UInt64(rawLine.count)
            let line = Data(rawLine)
            defer { lineStart += lineLength + 1 }
            guard !line.isEmpty else {
                continue
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                let event = try decoder.decode(MewsEvent.self, from: line)
                records.append(
                    EventLogRecord(
                        event: event,
                        startOffset: lineStart,
                        digest: EventLogFileIO.digest(line + Data([0x0A]))
                    )
                )
            } catch {
                throw EventLogReadError.malformedLine(lineStart)
            }
        }
        return records
    }

}

final class SessionEvidenceReader {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func scan(
        anchor: SessionReconciliationAnchor?,
        through boundary: SessionReconciliationAnchor? = nil,
        forceFull: Bool = false
    ) throws -> SessionEvidenceScan {
        let shouldForceFull = forceFull ||
            anchor == nil ||
            boundaryRequiresFullScan(anchor: anchor, boundary: boundary)
        let scan: EventLogFileScan
        do {
            scan = try EventLogFileScanner.scan(
                url: url,
                from: anchor?.offset ?? 0,
                anchor: anchor,
                through: boundary,
                forceFull: shouldForceFull
            )
        } catch EventLogReadError.anchorMismatch {
            scan = try EventLogFileScanner.scan(
                url: url,
                from: 0,
                anchor: nil,
                through: boundary,
                forceFull: true
            )
        }
        let events = scan.records.map(\.event).filter(\.affectsPrimaryStatus)
        return SessionEvidenceScan(
            events: events,
            candidateAnchor: scan.anchor,
            didResync: scan.didResync || shouldForceFull
        )
    }

    private func boundaryRequiresFullScan(
        anchor: SessionReconciliationAnchor?,
        boundary: SessionReconciliationAnchor?
    ) -> Bool {
        guard let anchor, let boundary else {
            return false
        }
        return anchor.fileIdentity != boundary.fileIdentity ||
            anchor.offset > boundary.offset
    }
}
