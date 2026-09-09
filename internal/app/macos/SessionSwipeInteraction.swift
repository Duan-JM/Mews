import Foundation

struct SessionSwipeMetrics: Equatable {
    static let standard = SessionSwipeMetrics(
        inputSlop: 8,
        horizontalLockRatio: 1.25,
        actionWidth: 44,
        revealThreshold: 8,
        commitThresholdRatio: 0.2,
        commitHysteresis: 16,
        revealedCloseThreshold: 24
    )

    static let actionInset: CGFloat = 6
    static let trailingGutter: CGFloat = 7

    let inputSlop: CGFloat
    let horizontalLockRatio: CGFloat
    let actionWidth: CGFloat
    let revealThreshold: CGFloat
    let commitThresholdRatio: CGFloat
    let commitHysteresis: CGFloat
    let revealedCloseThreshold: CGFloat

    func commitThreshold(rowWidth: CGFloat) -> CGFloat {
        return max(0, rowWidth * commitThresholdRatio)
    }

    func revealedWidth(rowWidth: CGFloat) -> CGFloat {
        return min(
            max(0, rowWidth),
            max(
                rowWidth * 0.1,
                actionWidth + 2 * Self.actionInset + Self.trailingGutter
            )
        )
    }
}

enum SessionSwipeAnimationPhysics {
    static func normalizedVelocity(
        velocityX: CGFloat,
        from startOffset: CGFloat,
        to targetOffset: CGFloat
    ) -> CGFloat {
        let displacement = targetOffset - startOffset
        guard abs(displacement) >= 1 else {
            return 0
        }
        return min(4, max(-4, velocityX / displacement))
    }
}

enum SessionSwipeAxisDecision: Equatable {
    case pending
    case horizontal
    case vertical
}

struct SessionSwipeAxisLock: Equatable {
    private(set) var decision = SessionSwipeAxisDecision.pending
    private(set) var translationX: CGFloat = 0
    private(set) var translationY: CGFloat = 0
    private let metrics: SessionSwipeMetrics

    init(metrics: SessionSwipeMetrics = .standard) {
        self.metrics = metrics
    }

    mutating func update(
        deltaX: CGFloat,
        deltaY: CGFloat
    ) -> SessionSwipeAxisDecision {
        translationX += deltaX
        translationY += deltaY
        guard decision == .pending else {
            return decision
        }
        guard hypot(translationX, translationY) >= metrics.inputSlop else {
            return .pending
        }
        decision = abs(translationX) >= abs(translationY) * metrics.horizontalLockRatio
            ? .horizontal
            : .vertical
        return decision
    }
}

enum SessionSwipePhase: Equatable {
    case resting
    case dragging
    case revealed
    case commitReady
    case committing
    case removing
    case failed
}

enum SessionSwipeResolution: Equatable {
    case closed
    case revealed
    case commit(SessionDismissalRequest, velocityX: CGFloat)
}

struct SessionSwipeInteraction: Equatable {
    private(set) var target: SessionDismissalRequest?
    private(set) var phase = SessionSwipePhase.resting
    private(set) var offset: CGFloat = 0
    private(set) var rowWidth: CGFloat = 0
    private(set) var releaseVelocityX: CGFloat = 0

    private var gestureStartOffset: CGFloat = 0
    private var didRequestThresholdFeedback = false
    private let metrics: SessionSwipeMetrics

    init(metrics: SessionSwipeMetrics = .standard) {
        self.metrics = metrics
    }

    var isInteractive: Bool {
        switch phase {
        case .dragging, .revealed, .commitReady, .failed:
            return true
        case .resting, .committing, .removing:
            return false
        }
    }

    mutating func begin(
        target: SessionDismissalRequest,
        rowWidth: CGFloat
    ) {
        let resumesRevealedTarget = self.target == target &&
            (phase == .revealed || phase == .failed)
        self.target = target
        self.rowWidth = max(0, rowWidth)
        gestureStartOffset = resumesRevealedTarget
            ? -metrics.revealedWidth(rowWidth: self.rowWidth)
            : 0
        offset = gestureStartOffset
        releaseVelocityX = 0
        didRequestThresholdFeedback = false
        phase = .dragging
    }

    mutating func update(translationX: CGFloat) -> Bool {
        guard phase == .dragging || phase == .commitReady else {
            return false
        }
        offset = min(0, max(-rowWidth, gestureStartOffset + translationX))
        let distance = -offset
        let threshold = metrics.commitThreshold(rowWidth: rowWidth)

        if phase == .commitReady {
            if distance < threshold - metrics.commitHysteresis {
                phase = .dragging
            }
            return false
        }
        guard distance > threshold else {
            return false
        }
        phase = .commitReady
        guard !didRequestThresholdFeedback else {
            return false
        }
        didRequestThresholdFeedback = true
        return true
    }

    mutating func end(velocityX: CGFloat) -> SessionSwipeResolution {
        guard let target,
              phase == .dragging || phase == .commitReady else {
            reset()
            return .closed
        }
        releaseVelocityX = velocityX
        if phase == .commitReady {
            phase = .committing
            return .commit(target, velocityX: velocityX)
        }

        let distance = -offset
        let revealedWidth = metrics.revealedWidth(rowWidth: rowWidth)
        let shouldCloseRevealed = gestureStartOffset < 0 &&
            distance < revealedWidth - metrics.revealedCloseThreshold
        let shouldReveal = !shouldCloseRevealed &&
            (gestureStartOffset < 0 || distance >= metrics.revealThreshold)
        if shouldReveal {
            phase = .revealed
            offset = -revealedWidth
            return .revealed
        }
        reset()
        return .closed
    }

    mutating func cancel() -> SessionSwipeResolution {
        guard target != nil,
              phase == .dragging || phase == .commitReady else {
            reset()
            return .closed
        }
        if gestureStartOffset < 0 {
            phase = .revealed
            offset = -metrics.revealedWidth(rowWidth: rowWidth)
            releaseVelocityX = 0
            return .revealed
        }
        reset()
        return .closed
    }

    mutating func requestCommit() -> SessionSwipeResolution? {
        guard let target,
              phase == .revealed || phase == .failed else {
            return nil
        }
        phase = .committing
        releaseVelocityX = 0
        return .commit(target, velocityX: 0)
    }

    mutating func markRemoving() {
        guard phase == .committing else {
            return
        }
        phase = .removing
    }

    mutating func markFailed() {
        guard target != nil else {
            return
        }
        phase = .failed
        offset = -metrics.revealedWidth(rowWidth: rowWidth)
        releaseVelocityX = 0
    }

    mutating func reset() {
        target = nil
        phase = .resting
        offset = 0
        rowWidth = 0
        releaseVelocityX = 0
        gestureStartOffset = 0
        didRequestThresholdFeedback = false
    }
}

enum SessionSwipeDelta {
    static func physical(
        x deltaX: CGFloat,
        y deltaY: CGFloat,
        isDirectionInvertedFromDevice: Bool
    ) -> CGPoint {
        let multiplier: CGFloat = isDirectionInvertedFromDevice ? -1 : 1
        return CGPoint(x: deltaX * multiplier, y: deltaY * multiplier)
    }
}
