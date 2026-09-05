import Foundation
import SwiftUI

@MainActor
extension SessionListPresentationModel {
    func commit(
        target: SessionDismissalRequest,
        velocityX: CGFloat
    ) {
        guard activeOperation == nil else {
            return
        }
        clearError()
        nextOperationToken &+= 1
        let token = nextOperationToken
        let operationEpoch = epoch
        activeOperation = (target, token)
        schedulePendingIndicator(
            target: target,
            token: token,
            epoch: operationEpoch
        )
        hide(target) { [weak self] result in
            DispatchQueue.main.async {
                self?.finishCommit(
                    target: target,
                    token: token,
                    epoch: operationEpoch,
                    velocityX: velocityX,
                    result: result
                )
            }
        }
    }

    private func finishCommit(
        target: SessionDismissalRequest,
        token: UInt64,
        epoch operationEpoch: UInt64,
        velocityX: CGFloat,
        result: Result<SessionDismissalResponse, Error>
    ) {
        guard epoch == operationEpoch else {
            if case let .failure(error) = result {
                log("Could not hide session after panel lifecycle changed: \(error)")
            }
            return
        }
        guard activeOperation?.target == target,
              activeOperation?.token == token else {
            if case let .failure(error) = result {
                log("Could not hide stale session target: \(error)")
            }
            return
        }
        activeOperation = nil
        switch result {
        case let .success(response):
            minimumRevision = response.snapshot.revision
            switch response.result {
            case .dismissed:
                beginRemoval(
                    target: target,
                    velocityX: velocityX,
                    token: token
                )
            case .alreadyDismissed:
                applyAlreadyDismissed(target: target)
            case .staleEvidence, .ineligibleState:
                closeCommittedInteraction()
            case .orderingUnavailable:
                rejectCommit(
                    message: "SESSION NOT READY TO HIDE",
                    announcement: "Could not verify the latest session yet."
                )
            }
        case let .failure(error):
            log("Could not hide session: \(error)")
            failCommit(
                target: target,
                message: "COULD NOT HIDE SESSION",
                announcement: "Could not hide session. The session remains active."
            )
        }
    }

    private func beginRemoval(
        target: SessionDismissalRequest,
        velocityX: CGFloat,
        token: UInt64
    ) {
        guard let row = snapshot.rows.first(where: { $0.dismissalRequest == target }) else {
            interaction.reset()
            return
        }
        let rowWidth = max(
            SessionSwipeMetrics.standard.actionWidth,
            interaction.rowWidth
        )
        interaction.markRemoving()
        removalTokens[row.id] = token
        suppressedRowIDs.insert(row.id)
        var visual = snapshot.visual(for: row)
        visual = SessionSwipeRowVisual(
            phase: .removing,
            offset: visual.offset,
            opacity: visual.opacity,
            height: visual.height,
            isPending: false
        )
        setVisual(visual, for: row.id)
        interaction.reset()

        if reduceMotion {
            beginReducedMotionRemoval(row: row, token: token)
        } else {
            beginSpatialRemoval(
                row: row,
                visual: visual,
                rowWidth: rowWidth,
                velocityX: velocityX,
                token: token
            )
        }
        scheduleRemovalWatchdog(rowID: row.id, token: token)
    }

    private func beginReducedMotionRemoval(
        row: SessionPresentationRow,
        token: UInt64
    ) {
        animateVisual(
            rowID: row.id,
            animation: .easeOut(duration: 0.1)
        ) { current in
            SessionSwipeRowVisual(
                phase: .removing,
                offset: current.offset,
                opacity: 0,
                height: current.height,
                isPending: false
            )
        }
    }

    private func beginSpatialRemoval(
        row: SessionPresentationRow,
        visual: SessionSwipeRowVisual,
        rowWidth: CGFloat,
        velocityX: CGFloat,
        token: UInt64
    ) {
        let currentOffset = visual.offset
        let destination = -rowWidth
        let normalizedVelocity = SessionSwipeAnimationPhysics.normalizedVelocity(
            velocityX: velocityX,
            from: currentOffset,
            to: destination
        )
        animateVisual(
            rowID: row.id,
            animation: .interpolatingSpring(
                mass: 1,
                stiffness: 300,
                damping: 32,
                initialVelocity: normalizedVelocity
            )
        ) { current in
            SessionSwipeRowVisual(
                phase: .removing,
                offset: destination,
                opacity: 0,
                height: current.height,
                isPending: false
            )
        }
        schedule(after: 0.06) { [weak self] in
            self?.animateVisual(
                rowID: row.id,
                animation: .easeInOut(duration: 0.16)
            ) { current in
                SessionSwipeRowVisual(
                    phase: .removing,
                    offset: current.offset,
                    opacity: current.opacity,
                    height: 0,
                    isPending: false
                )
            }
        }
    }

    private func applyAlreadyDismissed(
        target: SessionDismissalRequest
    ) {
        if let row = snapshot.rows.first(where: {
            $0.dismissalRequest == target
        }) {
            suppressedRowIDs.insert(row.id)
            snapshot.rows.removeAll { $0.id == row.id }
            snapshot.rowVisuals.removeValue(forKey: row.id)
        }
        interaction.reset()
        reconcilePresentedRows()
    }

    private func rejectCommit(
        message: String,
        announcement: String
    ) {
        closeCommittedInteraction()
        showError(message, announcement: announcement)
    }

    private func finishRemoval(
        rowID: SessionPresentationRowID,
        token: UInt64
    ) {
        guard removalTokens[rowID] == token else {
            return
        }
        removalTokens.removeValue(forKey: rowID)
        snapshot.rows.removeAll { $0.id == rowID }
        snapshot.rowVisuals.removeValue(forKey: rowID)
        reconcilePresentedRows()
    }

    private func failCommit(
        target: SessionDismissalRequest,
        message: String,
        announcement: String
    ) {
        if canonicalRows.contains(where: { $0.dismissalRequest == target }) {
            interaction.markFailed()
            animateInteraction(to: .failed)
        } else {
            interaction.reset()
            reconcilePresentedRows()
        }
        showError(message, announcement: announcement)
    }

    private func schedulePendingIndicator(
        target: SessionDismissalRequest,
        token: UInt64,
        epoch operationEpoch: UInt64
    ) {
        schedule(after: 0.1) { [weak self] in
            guard let self,
                  self.epoch == operationEpoch,
                  self.activeOperation?.target == target,
                  self.activeOperation?.token == token,
                  let row = self.snapshot.rows.first(where: {
                      $0.dismissalRequest == target
                  }) else {
                return
            }
            var visual = self.snapshot.visual(for: row)
            visual = SessionSwipeRowVisual(
                phase: .committing,
                offset: visual.offset,
                opacity: visual.opacity,
                height: visual.height,
                isPending: true
            )
            self.setVisual(visual, for: row.id)
        }
    }

    private func scheduleRemovalWatchdog(
        rowID: SessionPresentationRowID,
        token: UInt64
    ) {
        schedule(after: 0.38) { [weak self] in
            self?.finishRemoval(rowID: rowID, token: token)
        }
    }

    private func showError(
        _ message: String,
        announcement: String
    ) {
        snapshot.errorMessage = message
        errorSequence &+= 1
        let sequence = errorSequence
        announce(announcement)
        let errorEpoch = epoch
        schedule(after: 4) { [weak self] in
            guard let self,
                  self.epoch == errorEpoch,
                  self.errorSequence == sequence else {
                return
            }
            withAnimation(.easeOut(duration: 0.1)) {
                self.snapshot.errorMessage = nil
            }
        }
    }

    private func clearError() {
        guard snapshot.errorMessage != nil else {
            return
        }
        errorSequence &+= 1
        snapshot.errorMessage = nil
    }

    private func animateVisual(
        rowID: SessionPresentationRowID,
        animation: Animation,
        update: @escaping (SessionSwipeRowVisual) -> SessionSwipeRowVisual
    ) {
        guard let row = snapshot.rows.first(where: { $0.id == rowID }) else {
            return
        }
        withAnimation(animation) {
            setVisual(update(snapshot.visual(for: row)), for: rowID)
        }
    }

    private func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) {
        let identifier = UUID()
        let item = DispatchWorkItem { [weak self] in
            self?.scheduledWork.removeValue(forKey: identifier)
            action()
        }
        scheduledWork[identifier] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func removalToken(
        for rowID: SessionPresentationRowID
    ) -> UInt64? {
        return removalTokens[rowID]
    }

    func finishRemovalAnimation(
        rowID: SessionPresentationRowID,
        token: UInt64
    ) {
        finishRemoval(rowID: rowID, token: token)
    }

    func finalizeActiveRemovals() {
        for (rowID, token) in Array(removalTokens) {
            finishRemoval(rowID: rowID, token: token)
        }
    }
}
