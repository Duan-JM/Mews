import SwiftUI

@MainActor
extension SessionListPresentationModel {
    func animateInteraction(
        to phase: SessionSwipePhase,
        row suppliedRow: SessionPresentationRow? = nil,
        startOffset: CGFloat? = nil,
        velocityX: CGFloat = 0
    ) {
        let row = suppliedRow ?? interaction.target.flatMap { target in
            snapshot.rows.first(where: { $0.dismissalRequest == target })
        }
        guard let row else {
            return
        }
        let visual = phase == .resting
            ? SessionSwipeRowVisual.resting
            : visualForInteraction(phase: phase)
        let sourceOffset = startOffset ?? snapshot.visual(for: row).offset
        withAnimation(settleAnimation(
            from: sourceOffset,
            to: visual.offset,
            velocityX: velocityX
        )) {
            setVisual(visual, for: row.id)
        }
    }

    func setVisual(
        _ visual: SessionSwipeRowVisual,
        for rowID: SessionPresentationRowID
    ) {
        if visual == .resting {
            snapshot.rowVisuals.removeValue(forKey: rowID)
        } else {
            snapshot.rowVisuals[rowID] = visual
        }
    }

    func visualForInteraction(
        phase: SessionSwipePhase
    ) -> SessionSwipeRowVisual {
        return SessionSwipeRowVisual(
            phase: phase,
            offset: interaction.offset,
            opacity: 1,
            height: 42,
            isPending: false
        )
    }

    private func settleAnimation(
        from startOffset: CGFloat,
        to targetOffset: CGFloat,
        velocityX: CGFloat
    ) -> Animation {
        guard !reduceMotion else {
            return .easeOut(duration: 0.1)
        }
        let response = 0.28
        let dampingFraction = 0.86
        let angularFrequency = (2 * Double.pi) / response
        let stiffness = angularFrequency * angularFrequency
        let damping = 2 * dampingFraction * angularFrequency
        return .interpolatingSpring(
            mass: 1,
            stiffness: stiffness,
            damping: damping,
            initialVelocity: SessionSwipeAnimationPhysics.normalizedVelocity(
                velocityX: velocityX,
                from: startOffset,
                to: targetOffset
            )
        )
    }
}
