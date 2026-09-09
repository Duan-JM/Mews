import Foundation

extension MewsAppModelTests {
    static func testSessionListPresentationModel() throws {
        try testSingleRevealedSwipe()
        try testEvidenceChangeCancelsSwipe()
        try testSuccessfulRemovalAndRevisionGate()
        try testConcurrentRemovalTokens()
        try testNewEvidenceCancelsOldRemoval()
        try testFailedRemovalFeedback()
        try testDismissalResultPresentation()
        try testLifecycleInvalidatesCompletion()
        try testPendingIndicator()
        try testRemovalWatchdog()
    }

    private static func testSingleRevealedSwipe() throws {
        let first = try listRow(id: "first", evidenceID: "first-1")
        let second = try listRow(id: "second", evidenceID: "second-1")
        let model = SessionListPresentationModel { _, _ in }
        model.update(canonicalRows: [first, second], revision: 1)

        let firstTarget = try listTarget(first)
        model.inputRouter.begin(
            SessionSwipeInputTarget(request: firstTarget, rowWidth: 320)
        )
        model.inputRouter.change(translationX: -7, velocityX: -80)
        model.inputRouter.end(velocityX: -80)
        try listExpect(
            model.snapshot.visual(for: first) == .resting,
            "a swipe below the reveal threshold should not leave a partial offset"
        )

        model.inputRouter.begin(
            SessionSwipeInputTarget(request: firstTarget, rowWidth: 320)
        )
        model.inputRouter.change(translationX: -40, velocityX: -120)
        model.inputRouter.end(velocityX: -120)
        try listExpect(
            model.snapshot.visual(for: first).phase == .revealed &&
                model.snapshot.visual(for: first).offset == -63,
            "a short swipe should reveal the first row"
        )

        let secondTarget = try listTarget(second)
        model.prepareForInputTarget(secondTarget)
        model.inputRouter.begin(
            SessionSwipeInputTarget(request: secondTarget, rowWidth: 320)
        )
        model.inputRouter.change(translationX: -40, velocityX: -120)
        model.inputRouter.end(velocityX: -120)
        try listExpect(
            model.snapshot.visual(for: first) == .resting &&
                model.snapshot.visual(for: second).phase == .revealed,
            "starting another row should close the previously revealed row"
        )
        model.cancelForLifecycle()
    }

    private static func testEvidenceChangeCancelsSwipe() throws {
        let original = try listRow(id: "changed", evidenceID: "evidence-1")
        let replacement = try listRow(
            id: "changed",
            evidenceID: "evidence-2",
            dismissible: false
        )
        let model = SessionListPresentationModel { _, _ in }
        model.update(canonicalRows: [original], revision: 1)
        model.inputRouter.begin(
            SessionSwipeInputTarget(
                request: try listTarget(original),
                rowWidth: 320
            )
        )
        model.inputRouter.change(translationX: -70, velocityX: -200)
        model.update(canonicalRows: [replacement], revision: 2)

        try listExpect(
            model.snapshot.rows == [replacement] &&
                model.snapshot.visual(for: replacement) == .resting,
            "new evidence should replace the old swipe target without carrying its offset"
        )
        model.cancelForLifecycle()
    }

    private static func testSuccessfulRemovalAndRevisionGate() throws {
        let row = try listRow(id: "success", evidenceID: "success-1")
        var completion: ((Result<SessionDismissalResponse, Error>) -> Void)?
        let model = SessionListPresentationModel { _, callback in
            completion = callback
        }
        model.updateAccessibility(reduceMotion: true)
        model.update(canonicalRows: [row], revision: 1)
        model.requestHide(row, rowWidth: 320)
        try listExpect(completion != nil, "HIDE should submit the evidence-scoped request")

        completion?(.success(listResponse(result: .dismissed, revision: 3)))
        runMainLoop(for: 0.02)
        model.update(canonicalRows: [row], revision: 2)
        try listExpect(
            model.snapshot.visual(for: row).phase == .removing,
            "a stale pre-dismissal revision should not restore a persisted row"
        )
        guard let token = model.removalToken(for: row.id) else {
            throw SessionListTestError.expectation(
                "a successful dismissal should install a removal token"
            )
        }
        model.finishRemovalAnimation(rowID: row.id, token: token)
        try listExpect(
            model.snapshot.rows.isEmpty,
            "a completed removal should not re-add a row from the pre-dismissal cache"
        )
        model.update(canonicalRows: [], revision: 3)
        model.cancelForLifecycle()
    }

    private static func testDismissalResultPresentation() throws {
        let row = try listRow(id: "result", evidenceID: "result-1")
        var orderingAnnouncement: [String] = []
        let orderingModel = SessionListPresentationModel(
            hide: { _, completion in
                completion(.success(listResponse(
                    result: .orderingUnavailable,
                    revision: 2
                )))
            },
            announce: { orderingAnnouncement.append($0) }
        )
        orderingModel.update(canonicalRows: [row], revision: 1)
        orderingModel.requestHide(row, rowWidth: 320)
        runMainLoop(for: 0.02)
        try listExpect(
            orderingModel.snapshot.visual(for: row) == .resting &&
                orderingModel.snapshot.errorMessage == "SESSION NOT READY TO HIDE" &&
                orderingAnnouncement == ["Could not verify the latest session yet."],
            "ordering rejection should close the row and provide distinct feedback"
        )
        orderingModel.cancelForLifecycle()

        let staleModel = SessionListPresentationModel { _, completion in
            completion(.success(listResponse(result: .staleEvidence, revision: 2)))
        }
        staleModel.update(canonicalRows: [row], revision: 1)
        staleModel.requestHide(row, rowWidth: 320)
        runMainLoop(for: 0.02)
        try listExpect(
            staleModel.snapshot.visual(for: row) == .resting &&
                staleModel.snapshot.errorMessage == nil,
            "stale evidence should close without masquerading as a storage failure"
        )
        staleModel.cancelForLifecycle()

        let dismissedModel = SessionListPresentationModel { _, completion in
            completion(.success(listResponse(result: .alreadyDismissed, revision: 2)))
        }
        dismissedModel.update(canonicalRows: [row], revision: 1)
        dismissedModel.requestHide(row, rowWidth: 320)
        runMainLoop(for: 0.02)
        try listExpect(
            dismissedModel.snapshot.rows.isEmpty,
            "an idempotent dismissal should refresh without a duplicate exit animation"
        )
        dismissedModel.cancelForLifecycle()
    }

    private static func testFailedRemovalFeedback() throws {
        let row = try listRow(id: "failure", evidenceID: "failure-1")
        var announced: [String] = []
        var logs: [String] = []
        var attempt = 0
        let model = SessionListPresentationModel(
            hide: { _, completion in
                attempt += 1
                if attempt == 1 {
                    completion(.failure(SessionListTestError.writeFailed))
                }
            },
            log: { logs.append($0) },
            announce: { announced.append($0) }
        )
        model.update(canonicalRows: [row], revision: 1)
        model.requestHide(row, rowWidth: 320)
        runMainLoop(for: 0.02)

        let visual = model.snapshot.visual(for: row)
        try listExpect(
            visual.phase == .failed &&
                visual.offset == -63 &&
                model.snapshot.errorMessage == "COULD NOT HIDE SESSION",
            "a failed write should keep the row revealed and retryable"
        )
        try listExpect(
            logs.count == 1 &&
                announced == ["Could not hide session. The session remains active."],
            "a failed write should log once and announce the non-destructive result"
        )
        model.requestHide(row, rowWidth: 320)
        try listExpect(
            model.snapshot.errorMessage == nil,
            "retrying a failed dismissal should clear its stale error banner"
        )
        model.cancelForLifecycle()
    }

    private static func testConcurrentRemovalTokens() throws {
        let first = try listRow(id: "remove-first", evidenceID: "remove-1")
        let second = try listRow(id: "remove-second", evidenceID: "remove-2")
        var completions: [
            String: (Result<SessionDismissalResponse, Error>) -> Void
        ] = [:]
        let model = SessionListPresentationModel { request, completion in
            completions[request.identity.sessionID] = completion
        }
        model.update(canonicalRows: [first, second], revision: 1)
        model.requestHide(first, rowWidth: 320)
        completions[first.identity.sessionID]?(
            .success(listResponse(result: .dismissed, revision: 2))
        )
        runMainLoop(for: 0.02)
        model.requestHide(second, rowWidth: 320)
        completions[second.identity.sessionID]?(
            .success(listResponse(result: .dismissed, revision: 3))
        )
        runMainLoop(for: 0.02)

        guard let firstToken = model.removalToken(for: first.id),
              let secondToken = model.removalToken(for: second.id) else {
            throw SessionListTestError.expectation(
                "consecutive successful hides should own independent removal tokens"
            )
        }
        model.finishRemovalAnimation(rowID: first.id, token: firstToken)
        try listExpect(
            model.snapshot.rows == [second] &&
                model.snapshot.visual(for: second).phase == .removing,
            "finishing one removal must not finalize another row"
        )
        model.finishRemovalAnimation(rowID: second.id, token: secondToken)
        try listExpect(
            model.snapshot.rows.isEmpty,
            "each removal token should finalize only its matching row"
        )
        model.cancelForLifecycle()
    }

    private static func testNewEvidenceCancelsOldRemoval() throws {
        let original = try listRow(id: "replacement", evidenceID: "old")
        let replacement = try listRow(id: "replacement", evidenceID: "new")
        let model = SessionListPresentationModel { _, completion in
            completion(.success(listResponse(result: .dismissed, revision: 2)))
        }
        model.update(canonicalRows: [original], revision: 1)
        model.requestHide(original, rowWidth: 320)
        runMainLoop(for: 0.02)
        guard let oldToken = model.removalToken(for: original.id) else {
            throw SessionListTestError.expectation(
                "the old evidence should begin removal"
            )
        }
        model.update(canonicalRows: [replacement], revision: 3)
        model.finishRemovalAnimation(rowID: original.id, token: oldToken)
        try listExpect(
            model.snapshot.rows == [replacement] &&
                model.snapshot.visual(for: replacement) == .resting,
            "new evidence should replace an old removal without inheriting its callback"
        )
        model.cancelForLifecycle()
    }

    private static func testLifecycleInvalidatesCompletion() throws {
        let row = try listRow(id: "epoch", evidenceID: "epoch-1")
        var completion: ((Result<SessionDismissalResponse, Error>) -> Void)?
        var logs: [String] = []
        let model = SessionListPresentationModel(
            hide: { _, callback in
                completion = callback
            },
            log: { logs.append($0) }
        )
        model.update(canonicalRows: [row], revision: 1)
        model.requestHide(row, rowWidth: 320)
        model.cancelForLifecycle()
        completion?(.success(listResponse(result: .dismissed, revision: 2)))
        runMainLoop(for: 0.12)

        try listExpect(
            model.snapshot.rows == [row] &&
                model.snapshot.visual(for: row) == .resting,
            "a completion from an older panel epoch must not create a ghost removal"
        )

        var failedCompletion: ((Result<SessionDismissalResponse, Error>) -> Void)?
        model.requestHide(row, rowWidth: 320)
        failedCompletion = completion
        model.cancelForLifecycle()
        failedCompletion?(.failure(SessionListTestError.writeFailed))
        runMainLoop(for: 0.02)
        try listExpect(
            logs.count == 1 &&
                model.snapshot.errorMessage == nil,
            "a stale lifecycle failure should be logged without restoring stale UI"
        )
    }

    private static func testPendingIndicator() throws {
        let first = try listRow(id: "pending", evidenceID: "pending-1")
        let second = try listRow(id: "second-pending", evidenceID: "pending-2")
        var submitted: [SessionDismissalRequest] = []
        let model = SessionListPresentationModel { request, _ in
            submitted.append(request)
        }
        model.update(canonicalRows: [first, second], revision: 1)
        model.requestHide(first, rowWidth: 320)
        model.requestHide(second, rowWidth: 320)
        runMainLoop(for: 0.12)

        let visual = model.snapshot.visual(for: first)
        let firstTarget = try listTarget(first)
        try listExpect(
            visual.phase == .committing &&
                visual.isPending &&
                visual.actionOpacity == 1 &&
                visual.actionLabelOpacity == 0.7 &&
                submitted == [firstTarget] &&
                model.snapshot.visual(for: second) == .resting,
            "a pending write should dim HIDE and reject a second row submission"
        )
        model.cancelForLifecycle()
    }

    private static func testRemovalWatchdog() throws {
        let row = try listRow(id: "watchdog", evidenceID: "watchdog-1")
        let model = SessionListPresentationModel { _, completion in
            completion(.success(listResponse(result: .dismissed, revision: 2)))
        }
        model.update(canonicalRows: [row], revision: 1)
        model.requestHide(row, rowWidth: 320)
        runMainLoop(for: 0.42)
        try listExpect(
            model.snapshot.rows.isEmpty,
            "the bounded fallback should finalize an interrupted removal animation"
        )
        model.cancelForLifecycle()
    }

    static func listRow(
        id: String,
        evidenceID: String,
        dismissible: Bool = true
    ) throws -> SessionPresentationRow {
        guard let identity = SessionIdentity(source: "codex", sessionID: id) else {
            throw SessionListTestError.invalidFixture
        }
        let request = dismissible
            ? SessionDismissalRequest(identity: identity, evidenceID: evidenceID)
            : nil
        return SessionPresentationRow(
            identity: identity,
            status: dismissible ? .done : .running,
            sourceLabel: "Codex",
            projectLabel: "Mews",
            sessionLabel: id,
            statusLabel: dismissible ? "Stopped" : "Running",
            statusCode: dismissible ? "STOP" : "RUN",
            returnContext: nil,
            evidenceAt: Date(timeIntervalSince1970: 1_900_000_000),
            priority: dismissible ? .recent : .running,
            evidenceID: evidenceID,
            dismissalRequest: request
        )
    }

    private static func listTarget(
        _ row: SessionPresentationRow
    ) throws -> SessionDismissalRequest {
        guard let request = row.dismissalRequest else {
            throw SessionListTestError.invalidFixture
        }
        return request
    }

    private static func listResponse(
        result: SessionDismissalResult,
        revision: UInt64
    ) -> SessionDismissalResponse {
        return SessionDismissalResponse(
            result: result,
            snapshot: SessionControllerSnapshot(
                revision: revision,
                sessions: [],
                reconciliationAnchor: nil,
                orderingKnown: true
            )
        )
    }

    private static func runMainLoop(for duration: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    private static func listExpect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw SessionListTestError.expectation(message)
        }
    }
}

private enum SessionListTestError: Error {
    case invalidFixture
    case writeFailed
    case expectation(String)
}
