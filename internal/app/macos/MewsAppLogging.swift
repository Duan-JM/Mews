import Foundation

extension MewsApp {
    func logFile() -> FileHandle? {
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

    func appendAppLog(_ message: String) {
        guard let handle = logFile() else {
            return
        }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data("\(Date()) \(message)\n".utf8))
    }
}
