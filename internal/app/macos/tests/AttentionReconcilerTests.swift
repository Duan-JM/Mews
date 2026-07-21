import Foundation

extension MewsAppModelTests {
    static func testSemanticAttentionReconciliation() throws {
        try testRepeatedAttentionDeliversOnce()
        try testResolvedSessionCanAlertAgain()
        try testIndependentSessionAttention()
        try testSessionScopedAcknowledgement()
        try testAttentionRestartAndReplay()
        try testAttentionRemovalRequests()
        try testAttentionStoreValidation()
        try testAttentionControllerBehavior()
    }

    private static func testRepeatedAttentionDeliversOnce() throws {
        let candidate = try attentionCandidate(
            sessionID: "repeat",
            status: .done,
            changedAt: attentionTime(10)
        )
        let reconciler = AttentionReconciler()
        let first = reconciler.reconcile(candidates: [candidate], state: AttentionState())
        let repeated = reconciler.reconcile(candidates: [candidate], state: first.state)

        try attentionExpect(first.newlyAlertable == [candidate], "the first attention round should alert")
        try attentionExpect(
            first.newNotificationIdentifiers == [candidate.notificationIdentifier],
            "new attention should expose its stable notification identifier"
        )
        try attentionExpect(repeated.newlyAlertable.isEmpty, "repeated reconciliation should not redeliver")
        try attentionExpect(repeated.activeCount == 1, "delivered attention should remain active")
    }

    private static func testResolvedSessionCanAlertAgain() throws {
        let firstCandidate = try attentionCandidate(
            sessionID: "rounds",
            status: .done,
            changedAt: attentionTime(20)
        )
        let secondCandidate = try attentionCandidate(
            sessionID: "rounds",
            status: .failed,
            changedAt: attentionTime(40)
        )
        let reconciler = AttentionReconciler()
        let first = reconciler.reconcile(candidates: [firstCandidate], state: AttentionState())
        let resolved = reconciler.reconcile(candidates: [], state: first.state)
        let second = reconciler.reconcile(candidates: [secondCandidate], state: resolved.state)
        let directSecond = reconciler.reconcile(candidates: [secondCandidate], state: first.state)

        try attentionExpect(
            resolved.resolvedNotificationIdentifiers == [firstCandidate.notificationIdentifier],
            "running or idle state should resolve the prior attention identifier"
        )
        try attentionExpect(resolved.activeCount == 0, "resolved attention should leave no active count")
        try attentionExpect(
            second.newlyAlertable == [secondCandidate],
            "a later semantic transition should create a new alertable round"
        )
        try attentionExpect(
            secondCandidate.notificationIdentifier != firstCandidate.notificationIdentifier,
            "semantic rounds should have distinct stable identifiers"
        )
        try attentionExpect(
            directSecond.resolvedNotificationIdentifiers == [firstCandidate.notificationIdentifier],
            "a later round should remove the older delivered notification"
        )
    }

    private static func testIndependentSessionAttention() throws {
        let first = try attentionCandidate(
            sessionID: "independent-a",
            status: .needsInput,
            changedAt: attentionTime(50)
        )
        let second = try attentionCandidate(
            sessionID: "independent-b",
            status: .failed,
            changedAt: attentionTime(60)
        )
        let result = AttentionReconciler().reconcile(
            candidates: [second, first],
            state: AttentionState()
        )

        try attentionExpect(result.newlyAlertable.count == 2, "both sessions should alert independently")
        try attentionExpect(result.activeCount == 2, "active count should include both sessions")
    }

    private static func testSessionScopedAcknowledgement() throws {
        let first = try attentionCandidate(
            sessionID: "ack-a",
            status: .done,
            changedAt: attentionTime(70)
        )
        let second = try attentionCandidate(
            sessionID: "ack-b",
            status: .needsInput,
            changedAt: attentionTime(80)
        )
        let reconciler = AttentionReconciler()
        let delivered = reconciler.reconcile(candidates: [first, second], state: AttentionState())
        let acknowledged = reconciler.acknowledge(
            identity: first.identity,
            state: delivered.state
        )

        try attentionExpect(
            acknowledged.acknowledged == first.key,
            "Return to CLI should acknowledge the owning session current round"
        )
        try attentionExpect(acknowledged.activeCount == 1, "the other session should remain active")
        try attentionExpect(
            acknowledged.removalNotificationIdentifiers == [first.notificationIdentifier],
            "acknowledgement should request removal of the matching notification"
        )
        try attentionExpect(
            !CLIContextIntent.copy.acknowledgesAttention,
            "Copy Return Command must not acknowledge attention"
        )
        try attentionExpect(
            CLIContextIntent.open.acknowledgesAttention,
            "Return to CLI and default open actions should acknowledge attention"
        )

        let stale = reconciler.acknowledge(
            identity: second.identity,
            notificationIdentifier: first.notificationIdentifier,
            state: acknowledged.state
        )
        try attentionExpect(stale.acknowledged == nil, "a stale notification must not clear a later round")
        try attentionExpect(stale.activeCount == 1, "a stale action should leave current attention active")
    }

    private static func testAttentionRestartAndReplay() throws {
        let directory = try sessionScratchDirectory("attention-restart")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("attention.json")
        let candidate = try attentionCandidate(
            sessionID: "restart",
            status: .done,
            changedAt: attentionTime(90)
        )
        let first = try AttentionStateRepository(store: AttentionStateStore(url: url))
        let delivered = try first.reconcile(candidates: [candidate])
        try attentionExpect(delivered.newlyAlertable.count == 1, "initial repository delivery should persist")

        let restarted = try AttentionStateRepository(store: AttentionStateStore(url: url))
        let replayed = try restarted.reconcile(candidates: [candidate])
        try attentionExpect(replayed.newlyAlertable.isEmpty, "restart replay should not revive delivery")
        let acknowledged = try restarted.acknowledge(identity: candidate.identity)
        try attentionExpect(acknowledged.activeCount == 0, "acknowledgement should persist")

        let handledRestart = try AttentionStateRepository(store: AttentionStateStore(url: url))
        let handledReplay = try handledRestart.reconcile(candidates: [candidate])
        try attentionExpect(handledReplay.newlyAlertable.isEmpty, "restart should not revive acknowledged attention")
        try attentionExpect(handledReplay.activeCount == 0, "acknowledged replay should remain inactive")
    }

    private static func testAttentionRemovalRequests() throws {
        let candidate = try attentionCandidate(
            sessionID: "remove",
            status: .failed,
            changedAt: attentionTime(100)
        )
        let reconciler = AttentionReconciler()
        let delivered = reconciler.reconcile(candidates: [candidate], state: AttentionState())
        let resolved = reconciler.reconcile(candidates: [], state: delivered.state)

        try attentionExpect(
            resolved.resolved == [ResolvedAttention(key: candidate.key)],
            "resolution should identify the exact attention round"
        )
        try attentionExpect(
            resolved.resolvedNotificationIdentifiers == [candidate.notificationIdentifier],
            "resolution should request removal of the delivered identifier"
        )
    }

    private static func testAttentionStoreValidation() throws {
        let directory = try sessionScratchDirectory("attention-store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AttentionStateStore(url: directory.appendingPathComponent("attention.json"))
        let candidate = try attentionCandidate(
            sessionID: "stored",
            status: .needsInput,
            changedAt: attentionTime(110.123_456)
        )
        let delivered = AttentionReconciler().reconcile(
            candidates: [candidate],
            state: AttentionState()
        )
        try store.save(delivered.state)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        try attentionExpect(
            attributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o600),
            "attention state should use private permissions"
        )
        let loaded = try store.load()
        try attentionExpect(
            loaded == delivered.state,
            "attention state should round-trip through atomic storage"
        )
        try attentionExpect(
            loaded.persistedRecords.first?.key.notificationIdentifier ==
                candidate.notificationIdentifier,
            "notification identity should remain stable across persistence"
        )
        try assertAttentionSchemaValidation(store: store, state: delivered.state)
    }

    private static func assertAttentionSchemaValidation(
        store: AttentionStateStore,
        state: AttentionState
    ) throws {
        var object = try attentionRequire(
            try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any],
            "attention state should decode as an object"
        )
        object["unexpected"] = true
        try JSONSerialization.data(withJSONObject: object).write(to: store.url)
        do {
            _ = try store.load()
            throw AttentionTestFailure(message: "unknown schema keys should fail explicitly")
        } catch let error as AttentionStateStoreError {
            guard case .corruptData = error else {
                throw AttentionTestFailure(message: "unknown schema keys should report corruptData")
            }
        }

        try store.save(state)
        object = try attentionRequire(
            try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any],
            "saved attention state should decode again"
        )
        object["version"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: store.url)
        do {
            _ = try store.load()
            throw AttentionTestFailure(message: "unsupported attention versions should fail explicitly")
        } catch let error as AttentionStateStoreError {
            guard case .unsupportedVersion(2) = error else {
                throw AttentionTestFailure(message: "unsupported versions should preserve their version")
            }
        }
    }

}

private func attentionCandidate(
    sessionID: String,
    status: SessionStatus,
    changedAt: Date
) throws -> SessionAttentionCandidate {
    let identity = try attentionRequire(
        SessionIdentity(source: "copilot", sessionID: sessionID),
        "attention identity should be valid"
    )
    let session = CurrentSessionState(
        identity: identity,
        status: status,
        evidenceStatus: status,
        statusChangedAt: changedAt,
        evidenceAt: changedAt,
        project: "Mews",
        hookEvent: nil,
        returnContext: CLIContextPayload(
            returnCommand: sessionReturnCommand(sessionID),
            workingDirectory: nil
        ),
        isFresh: true
    )
    return try attentionRequire(
        SessionAttentionCandidate(session: session),
        "attention status should create a candidate"
    )
}

private func attentionTime(_ offset: TimeInterval) -> Date {
    return Date(timeIntervalSince1970: 1_800_100_000 + offset)
}

private func attentionRequire<Value>(_ value: Value?, _ message: String) throws -> Value {
    guard let value else {
        throw AttentionTestFailure(message: message)
    }
    return value
}

private func attentionExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else {
        throw AttentionTestFailure(message: message)
    }
}

private struct AttentionTestFailure: Error {
    let message: String
}
