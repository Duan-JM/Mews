import AppKit
import Foundation
import SwiftUI

enum SessionRowLayout {
    static let rowHeight: CGFloat = 42
    static let actionButtonWidth = SessionSwipeMetrics.standard.actionWidth
    static let actionButtonHeight: CGFloat = 24
    static let actionButtonCornerRadius: CGFloat = 4
    static let actionFontSize: CGFloat = 9
    static let actionTracking: CGFloat = 0.35
}

struct SessionSwipeRowVisual: Equatable {
    static let resting = SessionSwipeRowVisual(
        phase: .resting,
        offset: 0,
        opacity: 1,
        height: SessionRowLayout.rowHeight,
        isPending: false
    )

    let phase: SessionSwipePhase
    let offset: CGFloat
    let opacity: Double
    let height: CGFloat
    let isPending: Bool

    var revealWidth: CGFloat {
        return max(0, -offset)
    }

    var actionOpacity: Double {
        return revealWidth > 0 ? 1 : 0
    }

    var actionLabelOpacity: Double {
        return isPending ? 0.7 : 1
    }

    var actionAcceptsInput: Bool {
        return (phase == .revealed || phase == .failed) && !isPending
    }

    var acceptsSwipeInput: Bool {
        return phase != .committing && phase != .removing
    }

    func actionGeometry(rowWidth: CGFloat) -> SessionSwipeActionGeometry {
        let expanded = usesFullWidthAction(rowWidth: rowWidth)
        return SessionSwipeActionGeometry(
            trackWidth: expanded ? rowWidth : min(rowWidth, revealWidth)
        )
    }

    func contentOffset(rowWidth: CGFloat) -> CGFloat {
        return -actionGeometry(rowWidth: rowWidth).trackWidth
    }

    func actionWidth(rowWidth: CGFloat) -> CGFloat {
        return actionGeometry(rowWidth: rowWidth).buttonWidth
    }

    func actionHeight(rowWidth: CGFloat) -> CGFloat {
        return actionGeometry(rowWidth: rowWidth).height
    }

    func actionCornerRadius(rowWidth: CGFloat) -> CGFloat {
        return actionGeometry(rowWidth: rowWidth).cornerRadius
    }

    func actionVerticalOffset(rowWidth: CGFloat) -> CGFloat {
        return actionGeometry(rowWidth: rowWidth).verticalOffset
    }

    func usesFullWidthAction(rowWidth: CGFloat) -> Bool {
        return rowWidth > 0 &&
            (phase == .commitReady || phase == .committing || phase == .removing)
    }
}

struct SessionListPresentationSnapshot: Equatable {
    static let empty = SessionListPresentationSnapshot(
        rows: [],
        rowVisuals: [:],
        errorMessage: nil
    )

    var rows: [SessionPresentationRow]
    var rowVisuals: [SessionPresentationRowID: SessionSwipeRowVisual]
    var errorMessage: String?

    func visual(for row: SessionPresentationRow) -> SessionSwipeRowVisual {
        return rowVisuals[row.id] ?? .resting
    }
}

@MainActor
final class SessionListPresentationModel: ObservableObject {
    typealias HideHandler = (
        SessionDismissalRequest,
        @escaping (Result<SessionDismissalResponse, Error>) -> Void
    ) -> Void

    @Published var snapshot = SessionListPresentationSnapshot.empty

    let hide: HideHandler
    let log: (String) -> Void
    let announce: (String) -> Void
    var canonicalRows: [SessionPresentationRow] = []
    var interaction = SessionSwipeInteraction()
    private var lastRevision: UInt64?
    var minimumRevision: UInt64?
    var nextOperationToken: UInt64 = 0
    var activeOperation: (target: SessionDismissalRequest, token: UInt64)?
    var removalTokens: [SessionPresentationRowID: UInt64] = [:]
    var suppressedRowIDs: Set<SessionPresentationRowID> = []
    var scheduledWork: [UUID: DispatchWorkItem] = [:]
    var epoch: UInt64 = 0
    var errorSequence: UInt64 = 0
    var reduceMotion = false

    lazy var inputRouter = SessionSwipeInputRouter(
        onBegin: { [weak self] target, width in
            self?.beginSwipe(target: target, rowWidth: width)
        },
        onChange: { [weak self] translation, velocity in
            self?.updateSwipe(translationX: translation, velocityX: velocity)
        },
        onEnd: { [weak self] velocity in
            self?.endSwipe(velocityX: velocity)
        },
        onCancel: { [weak self] in
            self?.cancelSwipeInput()
        },
        onVerticalScroll: { [weak self] in
            self?.closeRevealedRow()
        }
    )

    init(
        hide: @escaping HideHandler,
        log: @escaping (String) -> Void = { _ in },
        announce: @escaping (String) -> Void = { _ in }
    ) {
        self.hide = hide
        self.log = log
        self.announce = announce
    }

    func update(
        canonicalRows: [SessionPresentationRow],
        revision: UInt64?
    ) {
        if let revision,
           let lastRevision,
           revision < lastRevision {
            return
        }
        if let revision {
            lastRevision = revision
        }
        if let minimumRevision {
            guard let revision, revision >= minimumRevision else {
                return
            }
            self.minimumRevision = nil
        }
        let incomingIDs = Set(canonicalRows.map(\.id))
        suppressedRowIDs = suppressedRowIDs.filter {
            incomingIDs.contains($0)
        }
        self.canonicalRows = canonicalRows
        reconcilePresentedRows()
    }

    func requestHide(
        _ row: SessionPresentationRow,
        rowWidth: CGFloat
    ) {
        guard activeOperation == nil,
              let request = row.dismissalRequest else {
            return
        }

        if interaction.target != request {
            closeRevealedRow()
            interaction.begin(target: request, rowWidth: max(1, rowWidth))
            _ = interaction.update(
                translationX: -SessionSwipeMetrics.standard.actionWidth
            )
            _ = interaction.end(velocityX: 0)
        }
        guard let resolution = interaction.requestCommit() else {
            return
        }
        handle(resolution)
    }

    func cancelForLifecycle() {
        epoch &+= 1
        scheduledWork.values.forEach { $0.cancel() }
        scheduledWork.removeAll()
        activeOperation = nil
        removalTokens.removeAll()
        interaction.reset()
        inputRouter.cancelAllInput()
        snapshot = SessionListPresentationSnapshot(
            rows: effectiveCanonicalRows,
            rowVisuals: [:],
            errorMessage: nil
        )
    }

    private func beginSwipe(
        target: SessionDismissalRequest,
        rowWidth: CGFloat
    ) {
        guard activeOperation == nil,
              effectiveCanonicalRows.contains(where: {
                  $0.dismissalRequest == target
              }) else {
            return
        }
        if interaction.target != target {
            cancelInteractiveSwipe(animated: true)
        }
        interaction.begin(target: target, rowWidth: rowWidth)
        publishInteraction()
    }

    private func updateSwipe(
        translationX: CGFloat,
        velocityX: CGFloat
    ) {
        guard activeOperation == nil else {
            return
        }
        let shouldPerformHaptic = interaction.update(translationX: translationX)
        publishInteraction()
        if shouldPerformHaptic {
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment,
                performanceTime: .now
            )
        }
        _ = velocityX
    }

    private func endSwipe(velocityX: CGFloat) {
        guard activeOperation == nil else {
            return
        }
        let row = interaction.target.flatMap { target in
            snapshot.rows.first(where: { $0.dismissalRequest == target })
        }
        let startOffset = interaction.offset
        let resolution = interaction.end(velocityX: velocityX)
        handle(
            resolution,
            settlingRow: row,
            startOffset: startOffset,
            velocityX: velocityX
        )
    }

    private func cancelSwipeInput() {
        let row = interaction.target.flatMap { target in
            snapshot.rows.first(where: { $0.dismissalRequest == target })
        }
        let startOffset = interaction.offset
        handle(
            interaction.cancel(),
            settlingRow: row,
            startOffset: startOffset,
            velocityX: 0
        )
    }

    private func handle(
        _ resolution: SessionSwipeResolution,
        settlingRow: SessionPresentationRow? = nil,
        startOffset: CGFloat? = nil,
        velocityX: CGFloat = 0
    ) {
        switch resolution {
        case .closed:
            animateInteraction(
                to: .resting,
                row: settlingRow,
                startOffset: startOffset,
                velocityX: velocityX
            )
        case .revealed:
            animateInteraction(
                to: .revealed,
                row: settlingRow,
                startOffset: startOffset,
                velocityX: velocityX
            )
        case let .commit(target, velocityX):
            publishInteraction()
            commit(target: target, velocityX: velocityX)
        }
    }

    private func cancelInteractiveSwipe(animated: Bool) {
        guard interaction.isInteractive,
              let target = interaction.target,
              let row = snapshot.rows.first(where: { $0.dismissalRequest == target }) else {
            return
        }
        let startOffset = interaction.offset
        interaction.reset()
        if animated {
            animateInteraction(
                to: .resting,
                row: row,
                startOffset: startOffset,
                velocityX: 0
            )
        } else {
            setVisual(.resting, for: row.id)
        }
    }

    func closeCommittedInteraction() {
        guard let target = interaction.target,
              let row = snapshot.rows.first(where: {
                  $0.dismissalRequest == target
              }) else {
            interaction.reset()
            reconcilePresentedRows()
            return
        }
        let startOffset = interaction.offset
        interaction.reset()
        animateInteraction(
            to: .resting,
            row: row,
            startOffset: startOffset,
            velocityX: 0
        )
    }

    private func publishInteraction() {
        guard let target = interaction.target,
              let row = snapshot.rows.first(where: { $0.dismissalRequest == target }) else {
            return
        }
        setVisual(visualForInteraction(phase: interaction.phase), for: row.id)
    }

}

@MainActor
extension SessionListPresentationModel {
    func updateAccessibility(reduceMotion: Bool) {
        let didChange = self.reduceMotion != reduceMotion
        self.reduceMotion = reduceMotion
        if didChange {
            finalizeActiveRemovals()
        }
    }

    func closeRevealedRow() {
        cancelInteractiveSwipe(animated: true)
    }

    func prepareForRowAction() {
        closeRevealedRow()
    }

    func prepareForInputTarget(_ target: SessionDismissalRequest) {
        if interaction.target != target {
            closeRevealedRow()
        }
    }
}
