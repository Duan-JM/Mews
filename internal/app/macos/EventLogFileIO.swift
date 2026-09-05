import Darwin
import Foundation

enum EventLogFileIO {
    static func openDescriptor(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw EventLogReadError.missingFile
            }
            throw EventLogReadError.openFailed(String(cString: strerror(errno)))
        }
        return descriptor
    }

    static func readData(
        descriptor: Int32,
        from offset: UInt64,
        through limit: UInt64?
    ) throws -> Data {
        guard lseek(descriptor, off_t(offset), SEEK_SET) >= 0 else {
            throw EventLogReadError.readFailed(String(cString: strerror(errno)))
        }
        if let limit {
            return try readExactly(descriptor: descriptor, count: Int(limit - offset))
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

    static func validate(
        anchor: SessionReconciliationAnchor,
        descriptor: Int32
    ) throws {
        if let prefixDigest = anchor.prefixDigest {
            guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
                throw EventLogReadError.readFailed(String(cString: strerror(errno)))
            }
            let bytes = try readExactly(descriptor: descriptor, count: Int(anchor.offset))
            guard digest(bytes) == prefixDigest else {
                throw EventLogReadError.anchorMismatch
            }
            return
        }
        guard let start = anchor.lineStartOffset,
              start < anchor.offset,
              let digest = anchor.lineDigest else {
            return
        }
        guard lseek(descriptor, off_t(start), SEEK_SET) >= 0 else {
            throw EventLogReadError.readFailed(String(cString: strerror(errno)))
        }
        let bytes = try readExactly(
            descriptor: descriptor,
            count: Int(anchor.offset - start)
        )
        guard self.digest(bytes) == digest else {
            throw EventLogReadError.anchorMismatch
        }
    }

    static func candidatePrefixDigest(
        prior: SessionReconciliationAnchor?,
        complete: Data,
        completeOffset: UInt64,
        descriptor: Int32
    ) throws -> String {
        if let prior,
           let prefixDigest = prior.prefixDigest,
           let priorHash = UInt64(prefixDigest, radix: 16) {
            return digest(complete, startingAt: priorHash)
        }
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw EventLogReadError.readFailed(String(cString: strerror(errno)))
        }
        return digest(
            try readExactly(descriptor: descriptor, count: Int(completeOffset))
        )
    }

    static func validateStableFile(
        descriptor: Int32,
        url: URL,
        initialStatus: stat,
        initialMetadata: EventLogFileMetadata
    ) throws {
        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw EventLogReadError.statFailed(String(cString: strerror(errno)))
        }
        guard after.st_ino == initialStatus.st_ino,
              after.st_dev == initialStatus.st_dev,
              metadata(of: after) == initialMetadata else {
            throw EventLogReadError.unstableFile
        }

        var pathStatus = stat()
        guard stat(url.path, &pathStatus) == 0,
              pathStatus.st_ino == initialStatus.st_ino,
              pathStatus.st_dev == initialStatus.st_dev,
              metadata(of: pathStatus) == initialMetadata else {
            throw EventLogReadError.unstableFile
        }
    }

    static func matchesCurrentFile(
        _ anchor: SessionReconciliationAnchor,
        at url: URL
    ) throws -> Bool {
        let descriptor = try openDescriptor(url)
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw EventLogReadError.statFailed(String(cString: strerror(errno)))
        }
        let metadata = metadata(of: status)
        guard identity(of: status) == anchor.fileIdentity,
              metadata == anchor.fileMetadata else {
            return false
        }
        try validate(anchor: anchor, descriptor: descriptor)
        try validateStableFile(
            descriptor: descriptor,
            url: url,
            initialStatus: status,
            initialMetadata: metadata
        )
        return true
    }

    static func digest(
        _ data: Data,
        startingAt initialHash: UInt64 = 14_695_981_039_346_656_037
    ) -> String {
        var hash = initialHash
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    static func identity(of fileStatus: stat) -> UInt64 {
        UInt64(fileStatus.st_ino) ^ UInt64(fileStatus.st_dev) &* 1_099_511_628_211
    }

    static func metadata(of fileStatus: stat) -> EventLogFileMetadata {
        return EventLogFileMetadata(
            size: UInt64(fileStatus.st_size),
            modificationSeconds: Int64(fileStatus.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(fileStatus.st_mtimespec.tv_nsec),
            changeSeconds: Int64(fileStatus.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(fileStatus.st_ctimespec.tv_nsec)
        )
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
}
