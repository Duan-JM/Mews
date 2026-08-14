import Foundation
import Network

struct AgentSocketPath {
    static func resolve(
        homeURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        userID: uid_t = getuid(),
        namespace: String? = ProcessInfo.processInfo.environment["MEWS_SOCKET_NAMESPACE"]
    ) -> String {
        let standardPath = homeURL
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Mews")
            .appendingPathComponent("mews.sock")
            .path
        guard standardPath.utf8.count >= 100 else {
            return standardPath
        }

        var directoryName = "mews-\(userID)"
        if let namespace, !namespace.isEmpty {
            directoryName += "-\(fnv1a(namespace))"
        }
        return temporaryDirectory
            .appendingPathComponent(directoryName)
            .appendingPathComponent("mews.sock")
            .path
    }

    private static func fnv1a(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

struct AgentSocketProbe {
    private static let queue = DispatchQueue(label: "dev.mews.agent-socket-probe")

    let path: String
    let timeout: TimeInterval

    init(
        path: String,
        timeout: TimeInterval = 0.5
    ) {
        self.path = path
        self.timeout = timeout
    }

    func check(completion: @escaping (Bool) -> Void) {
        let attempt = AgentSocketProbeAttempt(completion: completion)
        let connection = NWConnection(
            to: .unix(path: path),
            using: .tcp
        )
        attempt.start(
            connection: connection,
            timeout: timeout,
            queue: Self.queue
        )
        connection.stateUpdateHandler = { [weak connection] state in
            guard let connection else {
                attempt.finish(responsive: false)
                return
            }
            switch state {
            case .ready:
                sendPing(connection: connection, attempt: attempt)
            case .failed, .cancelled:
                attempt.finish(responsive: false)
            case .setup, .preparing, .waiting:
                break
            @unknown default:
                attempt.finish(responsive: false)
            }
        }
        connection.start(queue: Self.queue)
    }

    private func sendPing(
        connection: NWConnection,
        attempt: AgentSocketProbeAttempt
    ) {
        let request = Data("{\"type\":\"ping\"}\n".utf8)
        connection.send(content: request, completion: .contentProcessed { [weak connection] error in
            guard error == nil, let connection else {
                attempt.finish(responsive: false)
                return
            }
            receiveResponse(
                connection: connection,
                data: Data(),
                attempt: attempt
            )
        })
    }

    private func receiveResponse(
        connection: NWConnection,
        data: Data,
        attempt: AgentSocketProbeAttempt
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 4_096
        ) { [weak connection] received, _, isComplete, error in
            guard let connection else {
                attempt.finish(responsive: false)
                return
            }
            var response = data
            if let received {
                response.append(received)
            }
            if response.contains(0x0A) {
                attempt.finish(responsive: Self.isSuccessfulResponse(response))
            } else if error != nil || isComplete || response.count >= 4_096 {
                attempt.finish(responsive: false)
            } else {
                receiveResponse(
                    connection: connection,
                    data: response,
                    attempt: attempt
                )
            }
        }
    }

    private static func isSuccessfulResponse(_ data: Data) -> Bool {
        guard let newline = data.firstIndex(of: 0x0A),
              let object = try? JSONSerialization.jsonObject(with: data.prefix(upTo: newline)),
              let response = object as? [String: Any] else {
            return false
        }
        return response["ok"] as? Bool == true
    }
}

private final class AgentSocketProbeAttempt {
    private let lock = NSLock()
    private var completion: ((Bool) -> Void)?
    private var connection: NWConnection?
    private var finished = false

    init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    func start(
        connection: NWConnection,
        timeout: TimeInterval,
        queue: DispatchQueue
    ) {
        lock.lock()
        self.connection = connection
        lock.unlock()
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(responsive: false)
        }
    }

    func finish(responsive: Bool) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let connection = self.connection
        self.connection = nil
        let completion = self.completion
        self.completion = nil
        lock.unlock()
        connection?.cancel()
        completion?(responsive)
    }
}
