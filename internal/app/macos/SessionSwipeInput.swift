import AppKit
import Foundation

struct SessionSwipeInputTarget: Equatable {
    let request: SessionDismissalRequest
    let rowWidth: CGFloat
}

struct SessionSwipeVelocityTracker {
    private struct Sample {
        let deltaX: CGFloat
        let duration: TimeInterval
    }

    private(set) var velocityX: CGFloat = 0
    private var previousTimestamp: TimeInterval?
    private var samples: [Sample] = []

    mutating func update(
        deltaX: CGFloat,
        timestamp: TimeInterval
    ) {
        defer { previousTimestamp = timestamp }
        guard let previousTimestamp else {
            return
        }
        let duration = timestamp - previousTimestamp
        guard duration > 0 else {
            return
        }
        samples.append(Sample(deltaX: deltaX, duration: duration))
        if samples.count > 3 {
            samples.removeFirst()
        }
        let totalDuration = samples.reduce(0) { $0 + $1.duration }
        let totalDelta = samples.reduce(CGFloat.zero) { $0 + $1.deltaX }
        velocityX = totalDelta / totalDuration
    }
}

enum SessionSwipeScrollRouting {
    case consume
    case forward([NSEvent])
}

@MainActor
final class SessionSwipeInputRouter {
    typealias BeginHandler = (SessionDismissalRequest, CGFloat) -> Void
    typealias ChangeHandler = (CGFloat, CGFloat) -> Void
    typealias EndHandler = (CGFloat) -> Void
    typealias VoidHandler = () -> Void

    private struct RegisteredRow {
        weak var view: NSView?
        let request: SessionDismissalRequest
    }

    private enum ScrollState {
        case idle
        case pending
        case horizontal
        case vertical
    }

    private let onBegin: BeginHandler
    private let onChange: ChangeHandler
    private let onEnd: EndHandler
    private let onCancel: VoidHandler
    private let onVerticalScroll: VoidHandler
    private var rows: [ObjectIdentifier: RegisteredRow] = [:]
    private var scrollState = ScrollState.idle
    private var scrollTarget: SessionSwipeInputTarget?
    private var scrollAxisLock = SessionSwipeAxisLock()
    private var scrollVelocity = SessionSwipeVelocityTracker()
    private var bufferedScrollEvents: [NSEvent] = []
    private var consumesMomentum = false
    private weak var mouseRecognizer: SessionMouseSwipeRecognizer?

    init(
        onBegin: @escaping BeginHandler,
        onChange: @escaping ChangeHandler,
        onEnd: @escaping EndHandler,
        onCancel: @escaping VoidHandler,
        onVerticalScroll: @escaping VoidHandler
    ) {
        self.onBegin = onBegin
        self.onChange = onChange
        self.onEnd = onEnd
        self.onCancel = onCancel
        self.onVerticalScroll = onVerticalScroll
    }

    func register(
        view: NSView,
        request: SessionDismissalRequest
    ) {
        rows[ObjectIdentifier(view)] = RegisteredRow(
            view: view,
            request: request
        )
    }

    func unregister(view: NSView) {
        rows.removeValue(forKey: ObjectIdentifier(view))
    }

    func attach(mouseRecognizer: SessionMouseSwipeRecognizer) {
        self.mouseRecognizer = mouseRecognizer
    }

    func inputTarget(for event: NSEvent) -> SessionSwipeInputTarget? {
        rows = rows.filter { $0.value.view != nil }
        for row in rows.values {
            guard let view = row.view,
                  view.window === event.window else {
                continue
            }
            let point = view.convert(event.locationInWindow, from: nil)
            if view.bounds.contains(point) {
                return SessionSwipeInputTarget(
                    request: row.request,
                    rowWidth: view.bounds.width
                )
            }
        }
        return nil
    }

    func begin(_ target: SessionSwipeInputTarget) {
        onBegin(target.request, target.rowWidth)
    }

    func change(translationX: CGFloat, velocityX: CGFloat) {
        onChange(translationX, velocityX)
    }

    func end(velocityX: CGFloat) {
        onEnd(velocityX)
    }

    func cancel() {
        onCancel()
    }

    func beginVerticalInteraction() {
        onVerticalScroll()
    }

    func cancelAllInput() {
        let shouldCancel = scrollState == .horizontal ||
            mouseRecognizer?.hasActiveHorizontalSwipe == true
        resetScrollInput()
        mouseRecognizer?.cancelCapturedInput()
        if shouldCancel {
            onCancel()
        }
    }

    func routeScrollWheel(_ event: NSEvent) -> SessionSwipeScrollRouting {
        guard event.hasPreciseScrollingDeltas else {
            onVerticalScroll()
            return .forward([event])
        }
        if event.phase.isEmpty {
            if !event.momentumPhase.isEmpty {
                return routeMomentum(event)
            }
            onVerticalScroll()
            return .forward([event])
        }
        if event.phase.contains(.mayBegin) {
            beginScrollSequence(event)
        } else if event.phase.contains(.began), scrollState == .idle {
            beginScrollSequence(event)
        } else if scrollState == .idle {
            beginScrollSequence(event)
        }

        switch scrollState {
        case .vertical:
            let routing = SessionSwipeScrollRouting.forward([event])
            finishScrollSequenceIfNeeded(event)
            return routing
        case .horizontal:
            updateHorizontalScroll(event)
            finishScrollSequenceIfNeeded(event)
            return .consume
        case .idle, .pending:
            return resolvePendingScroll(event)
        }
    }

    private func beginScrollSequence(_ event: NSEvent) {
        resetScrollInput()
        scrollState = .pending
        scrollTarget = inputTarget(for: event)
    }

    private func resolvePendingScroll(
        _ event: NSEvent
    ) -> SessionSwipeScrollRouting {
        bufferedScrollEvents.append(event)
        let delta = physicalDelta(for: event)
        scrollVelocity.update(deltaX: delta.x, timestamp: event.timestamp)
        let decision = scrollAxisLock.update(deltaX: delta.x, deltaY: delta.y)

        if decision == .horizontal, let scrollTarget {
            scrollState = .horizontal
            begin(scrollTarget)
            change(
                translationX: scrollAxisLock.translationX,
                velocityX: scrollVelocity.velocityX
            )
            bufferedScrollEvents.removeAll(keepingCapacity: true)
            finishScrollSequenceIfNeeded(event)
            return .consume
        }
        if decision == .vertical || scrollTarget == nil {
            scrollState = .vertical
            onVerticalScroll()
            let events = bufferedScrollEvents
            bufferedScrollEvents.removeAll(keepingCapacity: true)
            finishScrollSequenceIfNeeded(event)
            return .forward(events)
        }
        if isTerminal(event.phase) {
            let events = bufferedScrollEvents
            resetScrollInput()
            return .forward(events)
        }
        return .consume
    }

    private func updateHorizontalScroll(_ event: NSEvent) {
        let delta = physicalDelta(for: event)
        _ = scrollAxisLock.update(deltaX: delta.x, deltaY: delta.y)
        scrollVelocity.update(deltaX: delta.x, timestamp: event.timestamp)
        change(
            translationX: scrollAxisLock.translationX,
            velocityX: scrollVelocity.velocityX
        )
    }

    private func finishScrollSequenceIfNeeded(_ event: NSEvent) {
        if event.phase.contains(.cancelled) {
            if scrollState == .horizontal {
                cancel()
            }
            resetScrollInput()
            return
        }
        guard event.phase.contains(.ended) else {
            return
        }
        if scrollState == .horizontal {
            end(velocityX: scrollVelocity.velocityX)
            consumesMomentum = true
        }
        resetScrollInput(preservingMomentum: true)
    }

    private func routeMomentum(_ event: NSEvent) -> SessionSwipeScrollRouting {
        guard consumesMomentum else {
            return .forward([event])
        }
        if isTerminal(event.momentumPhase) {
            consumesMomentum = false
        }
        return .consume
    }

    private func physicalDelta(for event: NSEvent) -> CGPoint {
        return SessionSwipeDelta.physical(
            x: event.scrollingDeltaX,
            y: event.scrollingDeltaY,
            isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice
        )
    }

    private func isTerminal(_ phase: NSEvent.Phase) -> Bool {
        return phase.contains(.ended) || phase.contains(.cancelled)
    }

    private func resetScrollInput(preservingMomentum: Bool = false) {
        scrollState = .idle
        scrollTarget = nil
        scrollAxisLock = SessionSwipeAxisLock()
        scrollVelocity = SessionSwipeVelocityTracker()
        bufferedScrollEvents.removeAll(keepingCapacity: true)
        if !preservingMomentum {
            consumesMomentum = false
        }
    }
}

@MainActor
final class SessionMouseSwipeRecognizer: NSGestureRecognizer {
    private weak var inputRouter: SessionSwipeInputRouter?
    private var inputTarget: SessionSwipeInputTarget?
    private var axisLock = SessionSwipeAxisLock()
    private var lastPoint = CGPoint.zero
    private var velocity = SessionSwipeVelocityTracker()
    private var consumesNonHorizontalDrag = false

    var hasActiveHorizontalSwipe: Bool {
        return inputTarget != nil &&
            !consumesNonHorizontalDrag &&
            axisLock.decision == .horizontal
    }

    init(inputRouter: SessionSwipeInputRouter) {
        self.inputRouter = inputRouter
        super.init(target: nil, action: nil)
        delaysPrimaryMouseButtonEvents = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let inputTarget = inputRouter?.inputTarget(for: event) else {
            state = .failed
            return
        }
        self.inputTarget = inputTarget
        lastPoint = event.locationInWindow
        velocity = SessionSwipeVelocityTracker()
        axisLock = SessionSwipeAxisLock()
        consumesNonHorizontalDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let inputTarget else {
            state = .failed
            return
        }
        let point = event.locationInWindow
        let delta = CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y)
        lastPoint = point
        velocity.update(deltaX: delta.x, timestamp: event.timestamp)

        switch axisLock.update(deltaX: delta.x, deltaY: delta.y) {
        case .pending:
            return
        case .vertical:
            if state == .possible {
                consumesNonHorizontalDrag = true
                state = .began
                inputRouter?.beginVerticalInteraction()
            } else {
                state = .changed
            }
        case .horizontal:
            if state == .possible {
                state = .began
                inputRouter?.begin(inputTarget)
            } else {
                state = .changed
            }
            inputRouter?.change(
                translationX: axisLock.translationX,
                velocityX: velocity.velocityX
            )
        }
    }

    override func mouseUp(with event: NSEvent) {
        if state == .began || state == .changed {
            if !consumesNonHorizontalDrag {
                inputRouter?.end(velocityX: velocity.velocityX)
            }
            state = .ended
        } else {
            state = .failed
        }
    }

    override func reset() {
        let shouldCancel = inputTarget != nil &&
            !consumesNonHorizontalDrag &&
            (state == .began || state == .changed || state == .cancelled)
        inputTarget = nil
        axisLock = SessionSwipeAxisLock()
        velocity = SessionSwipeVelocityTracker()
        consumesNonHorizontalDrag = false
        super.reset()
        if shouldCancel {
            inputRouter?.cancel()
        }
    }

    func cancelCapturedInput() {
        let hadTarget = inputTarget != nil
        inputTarget = nil
        axisLock = SessionSwipeAxisLock()
        velocity = SessionSwipeVelocityTracker()
        consumesNonHorizontalDrag = false
        guard hadTarget else {
            return
        }
        switch state {
        case .possible:
            state = .failed
        case .began, .changed:
            state = .cancelled
        default:
            break
        }
    }
}
