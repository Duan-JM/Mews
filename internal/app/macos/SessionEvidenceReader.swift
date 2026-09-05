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

    init(
        fileIdentity: UInt64,
        offset: UInt64,
        lastEventID: String?,
        lineDigest: String?,
        lineStartOffset: UInt64? = nil,
        fileMetadata: EventLogFileMetadata? = nil
    ) {
        self.fileIdentity = fileIdentity
        self.offset = offset
        self.lastEventID = lastEventID
        self.lineDigest = lineDigest
        self.lineStartOffset = lineStartOffset
        self.fileMetadata = fileMetadata
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
}

enum EventLogFileScanner {
    static func scan(
        url: URL,
        from offset: UInt64,
        anchor: SessionReconciliationAnchor?,
        forceFull: Bool = false
    ) throws -> EventLogFileScan {
        for _ in 0..<3 {
            do {
                return try scanOnce(
                    url: url,
                    from: offset,
                    anchor: anchor,
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
        forceFull: Bool
    ) throws -> EventLogFileScan {
        let descriptor = try openDescriptor(url)
        defer { close(descriptor) }

        let start = try scanStart(
            descriptor: descriptor,
            offset: offset,
            anchor: anchor,
            forceFull: forceFull
        )
        let data = try readData(descriptor: descriptor, from: start.readOffset)
        let complete: Data
        if let newline = data.lastIndex(of: 0x0A) {
            complete = Data(data.prefix(through: newline))
        } else {
            complete = Data()
        }
        let records = try decodeRecords(complete, baseOffset: start.readOffset)
        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw EventLogReadError.statFailed(String(cString: strerror(errno)))
        }
        guard after.st_ino == start.fileStatus.st_ino,
              after.st_dev == start.fileStatus.st_dev,
              metadata(of: after) == start.fileMetadata else {
            throw EventLogReadError.unstableFile
        }

        var pathStat = stat()
        guard stat(url.path, &pathStat) == 0,
              pathStat.st_ino == start.fileStatus.st_ino,
              pathStat.st_dev == start.fileStatus.st_dev,
              metadata(of: pathStat) == start.fileMetadata else {
            throw EventLogReadError.unstableFile
        }
        let completeOffset = start.readOffset + UInt64(complete.count)
        return EventLogFileScan(
            records: records,
            completeOffset: completeOffset,
            anchor: candidateAnchor(
                records: records,
                prior: forceFull ? nil : anchor,
                fileIdentity: start.fileIdentity,
                completeOffset: completeOffset,
                fileMetadata: start.fileMetadata
            ),
            fileIdentity: start.fileIdentity,
            didResync: forceFull
        )
    }

    private static func scanStart(
        descriptor: Int32,
        offset: UInt64,
        anchor: SessionReconciliationAnchor?,
        forceFull: Bool
    ) throws -> EventLogScanStart {
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0 else {
            throw EventLogReadError.statFailed(String(cString: strerror(errno)))
        }
        let fileIdentity = identity(of: fileStatus)
        let fileMetadata = metadata(of: fileStatus)
        guard !forceFull else {
            return EventLogScanStart(
                fileStatus: fileStatus,
                fileIdentity: fileIdentity,
                fileMetadata: fileMetadata,
                readOffset: 0
            )
        }
        guard let anchor,
              anchor.fileIdentity == fileIdentity,
              fileMetadata.size >= offset else {
            throw EventLogReadError.anchorMismatch
        }
        if let priorMetadata = anchor.fileMetadata,
           fileMetadata.size <= priorMetadata.size,
           fileMetadata != priorMetadata {
            throw EventLogReadError.anchorMismatch
        }
        try validateAnchor(anchor, descriptor: descriptor)
        return EventLogScanStart(
            fileStatus: fileStatus,
            fileIdentity: fileIdentity,
            fileMetadata: fileMetadata,
            readOffset: offset
        )
    }

    private static func openDescriptor(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw EventLogReadError.missingFile
            }
            throw EventLogReadError.openFailed(String(cString: strerror(errno)))
        }
        return descriptor
    }

    private static func candidateAnchor(
        records: [EventLogRecord],
        prior: SessionReconciliationAnchor?,
        fileIdentity: UInt64,
        completeOffset: UInt64,
        fileMetadata: EventLogFileMetadata
    ) -> SessionReconciliationAnchor {
        guard let last = records.last else {
            return prior ?? SessionReconciliationAnchor(
                fileIdentity: fileIdentity,
                offset: completeOffset,
                lastEventID: nil,
                lineDigest: nil,
                fileMetadata: fileMetadata
            )
        }
        return SessionReconciliationAnchor(
            fileIdentity: fileIdentity,
            offset: completeOffset,
            lastEventID: last.event.id,
            lineDigest: last.digest,
            lineStartOffset: last.startOffset,
            fileMetadata: fileMetadata
        )
    }

    private static func validateAnchor(
        _ anchor: SessionReconciliationAnchor,
        descriptor: Int32
    ) throws {
        guard let start = anchor.lineStartOffset,
              start < anchor.offset,
              let digest = anchor.lineDigest else {
            return
        }
        guard lseek(descriptor, off_t(start), SEEK_SET) >= 0 else {
            throw EventLogReadError.readFailed(String(cString: strerror(errno)))
        }
        let length = Int(anchor.offset - start)
        let bytes = try readExactly(descriptor: descriptor, count: length)
        guard fnvDigest(bytes) == digest else {
            throw EventLogReadError.anchorMismatch
        }
    }

    private static func readData(descriptor: Int32, from offset: UInt64) throws -> Data {
        guard lseek(descriptor, off_t(offset), SEEK_SET) >= 0 else {
            throw EventLogReadError.readFailed(String(cString: strerror(errno)))
        }
        var result = Data()
        while true {
            do {
                let chunk = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                    .read(upToCount: 64 * 1024)
                guard let chunk, !chunk.isEmpty else {
                    return result
                }
                result.append(chunk)
            } catch {
                throw EventLogReadError.readFailed(error.localizedDescription)
            }
        }
    }

    private static func readExactly(descriptor: Int32, count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            do {
                let chunk = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                    .read(upToCount: count - result.count)
                guard let chunk, !chunk.isEmpty else {
                    throw EventLogReadError.anchorMismatch
                }
                result.append(chunk)
            } catch let error as EventLogReadError {
                throw error
            } catch {
                throw EventLogReadError.readFailed(error.localizedDescription)
            }
        }
        return result
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
                        digest: fnvDigest(line + Data([0x0A]))
                    )
                )
            } catch {
                throw EventLogReadError.malformedLine(lineStart)
            }
        }
        return records
    }

    private static func fnvDigest(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func identity(of fileStatus: stat) -> UInt64 {
        UInt64(fileStatus.st_ino) ^ UInt64(fileStatus.st_dev) &* 1_099_511_628_211
    }

    private static func metadata(of fileStatus: stat) -> EventLogFileMetadata {
        return EventLogFileMetadata(
            size: UInt64(fileStatus.st_size),
            modificationSeconds: Int64(fileStatus.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(fileStatus.st_mtimespec.tv_nsec),
            changeSeconds: Int64(fileStatus.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(fileStatus.st_ctimespec.tv_nsec)
        )
    }
}

final class SessionEvidenceReader {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func scan(anchor: SessionReconciliationAnchor?) throws -> SessionEvidenceScan {
        let forceFull = anchor == nil
        let scan: EventLogFileScan
        do {
            scan = try EventLogFileScanner.scan(
                url: url,
                from: anchor?.offset ?? 0,
                anchor: anchor,
                forceFull: forceFull
            )
        } catch EventLogReadError.anchorMismatch {
            scan = try EventLogFileScanner.scan(
                url: url,
                from: 0,
                anchor: nil,
                forceFull: true
            )
        }
        let events = scan.records.map(\.event).filter(\.affectsPrimaryStatus)
        return SessionEvidenceScan(
            events: events,
            candidateAnchor: scan.anchor,
            didResync: scan.didResync || forceFull
        )
    }

}
