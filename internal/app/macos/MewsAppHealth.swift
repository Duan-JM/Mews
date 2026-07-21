import Foundation

@MainActor
extension MewsApp {
    func loadRuntimeHealth() -> RuntimeHealthSnapshot? {
        do {
            let snapshot = try RuntimeHealthSnapshotReader(
                url: storeDirectoryURL.appendingPathComponent("runtime-health.json")
            ).load()
            clearRuntimeHealthError()
            return snapshot
        } catch {
            recordRuntimeHealthError("Could not read runtime health: \(error)")
            return nil
        }
    }

    private func recordRuntimeHealthError(_ message: String) {
        guard runtimeHealthErrorMessage != message else {
            return
        }
        runtimeHealthErrorMessage = message
        appendAppLog(message)
    }

    private func clearRuntimeHealthError() {
        guard runtimeHealthErrorMessage != nil else {
            return
        }
        runtimeHealthErrorMessage = nil
        appendAppLog("Runtime health presentation recovered")
    }
}
