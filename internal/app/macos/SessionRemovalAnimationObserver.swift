import SwiftUI

struct SessionRemovalAnimationObserver: AnimatableModifier {
    typealias AnimatableData = AnimatablePair<
        CGFloat,
        AnimatablePair<Double, CGFloat>
    >

    var offset: CGFloat
    var opacity: Double
    var height: CGFloat
    let targetOffset: CGFloat
    let requiresSpatialCompletion: Bool
    let isActive: Bool
    let onCompletion: () -> Void

    var animatableData: AnimatableData {
        get {
            return AnimatablePair(
                offset,
                AnimatablePair(opacity, height)
            )
        }
        set {
            offset = newValue.first
            opacity = newValue.second.first
            height = newValue.second.second
            reportCompletionIfNeeded()
        }
    }

    func body(content: Content) -> some View {
        return content
    }

    private func reportCompletionIfNeeded() {
        guard isActive,
              opacity <= 0.01 else {
            return
        }
        if requiresSpatialCompletion {
            guard abs(offset - targetOffset) <= 0.5,
                  height <= 0.5 else {
                return
            }
        }
        DispatchQueue.main.async {
            onCompletion()
        }
    }
}
