import AppKit

@MainActor
final class NotchShellAnimation {
    struct Frame {
        let layout: NotchShellLayout
        let velocity: SIMD4<Double>
    }

    private static let frequency = 2 * Double.pi / 0.3
    private static let decay = frequency * 0.88
    private static let oscillation = frequency * sqrt(1 - 0.88 * 0.88)
    private let origin: SIMD4<Double>
    private let target: SIMD4<Double>
    private let initialVelocity: SIMD4<Double>
    private let clock: () -> TimeInterval
    private var timer: Timer?
    private(set) var currentFrame: Frame
    // Settle the displacement envelope to 0.01% before snapping to the exact target.
    let duration = -log(0.0001) / NotchShellAnimation.decay
    var onFrame: ((Frame) -> Void)?

    init(
        from: NotchShellLayout, to: NotchShellLayout, velocity: SIMD4<Double> = .zero,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        origin = from.components
        target = to.components
        initialVelocity = velocity
        self.clock = clock
        currentFrame = Frame(layout: from, velocity: velocity)
    }

    deinit {
        timer?.invalidate()
    }

    func start() {
        stop()
        let startedAt = clock()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                let elapsed = self.clock() - startedAt
                self.currentFrame = self.frame(at: elapsed)
                self.onFrame?(self.currentFrame)
                if elapsed >= self.duration {
                    self.stop()
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func frame(at time: TimeInterval) -> Frame {
        if time >= duration {
            return Frame(layout: NotchShellLayout(components: target), velocity: .zero)
        }
        let displacement = origin - target
        let sineWeight = (initialVelocity + displacement * Self.decay) / Self.oscillation
        let angle = Self.oscillation * time
        let envelope = exp(-Self.decay * time)
        let wave = displacement * cos(angle) + sineWeight * sin(angle)
        let derivative = (sineWeight * cos(angle) - displacement * sin(angle)) * Self.oscillation
        return Frame(
            layout: NotchShellLayout(components: target + wave * envelope),
            velocity: (derivative - wave * Self.decay) * envelope
        )
    }
}

private extension NotchShellLayout {
    var components: SIMD4<Double> {
        return SIMD4(Double(width), Double(height), Double(cornerRadius), Double(contentTopInset))
    }

    init(components: SIMD4<Double>) {
        self.init(
            width: CGFloat(components[0]), height: CGFloat(components[1]),
            cornerRadius: CGFloat(components[2]), contentTopInset: CGFloat(components[3])
        )
    }
}
