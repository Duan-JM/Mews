import Foundation

enum NotchVisibility: Equatable {
    case closed
    case peek
    case expanded
}

enum NotchOpenReason: Equatable {
    case click
    case hover
    case notification
}

enum NotchShellTransitionStyle: Equatable {
    case spatial
    case opacityOnly

    static func resolved(reduceMotion: Bool) -> NotchShellTransitionStyle {
        return reduceMotion ? .opacityOnly : .spatial
    }
}

enum StatusItemMouseButton: Equatable {
    case primary
    case secondary
}

enum StatusItemClickIntent: Equatable {
    case primaryAction
    case contextMenu

    static func resolve(
        button: StatusItemMouseButton,
        controlPressed: Bool
    ) -> StatusItemClickIntent {
        if button == .secondary || controlPressed {
            return .contextMenu
        }
        return .primaryAction
    }
}

enum NotchInteractionTiming {
    static let hoverOpen: TimeInterval = 0.45
    static let hoverClose: TimeInterval = 0.25
    static let stoppedPulse: TimeInterval = 2
}

enum NotchInteractionAction: Equatable {
    case logoPrimaryClick
    case notchClick(isPanelControl: Bool)
    case panelSurfaceClick(isPanelControl: Bool)
    case outsideClick
    case pointerMoved(isInsideNotch: Bool, isInsideInteractiveSurface: Bool)
    case hoverOpenTimerFired
    case hoverCloseTimerFired
    case notificationPeekTimerFired(sequence: Int)
    case placementUnavailable
    case stoppedTransition(identifier: String)
    case presentationSynchronized(MewsPresentationState)
    case presentationChanged(MewsPresentationState)
}

enum NotchInteractionEffect: Equatable {
    case scheduleHoverOpen(after: TimeInterval)
    case cancelHoverOpen
    case scheduleHoverClose(after: TimeInterval)
    case cancelHoverClose
    case scheduleNotificationPeek(sequence: Int, after: TimeInterval)
    case cancelNotificationPeek
}

struct NotchInteractionState: Equatable {
    fileprivate(set) var visibility: NotchVisibility
    fileprivate(set) var openReason: NotchOpenReason?
    fileprivate(set) var presentationState: MewsPresentationState
    var stopPulseActive: Bool { activeNotificationPeekSequence != nil }

    fileprivate var pointerInsideNotch = false
    fileprivate var pointerInsideInteractiveSurface = false
    fileprivate var hoverOpenPending = false
    fileprivate var hoverClosePending = false
    fileprivate var activeNotificationPeekSequence: Int?
    fileprivate var nextNotificationPeekSequence = 0
    fileprivate var handledTransitionIdentifiers: Set<String> = []
    fileprivate var handledTransitionOrder: [String] = []

    init(
        visibility: NotchVisibility = .closed,
        openReason: NotchOpenReason? = nil,
        presentationState: MewsPresentationState
    ) {
        self.visibility = visibility
        self.openReason = openReason
        self.presentationState = presentationState
    }
}

struct NotchPanelPresentationPolicy {
    static func isVisible(
        visibility: NotchVisibility,
        placementMode: OverlayPlacementMode,
        hasCollapsedSignal: Bool
    ) -> Bool {
        switch placementMode {
        case .notch:
            return visibility == .expanded || hasCollapsedSignal
        case .topCenter:
            return visibility == .expanded
        }
    }

    static func acceptsMouseEvents(visibility: NotchVisibility) -> Bool {
        return visibility == .expanded
    }
}

func notchTransitionIsNew(
    latestEvent: MewsEvent?,
    newEvents: [MewsEvent]
) -> Bool {
    guard let latestEvent else {
        return false
    }
    return newEvents.contains { $0.id == latestEvent.id }
}

struct NotchInteractionModel {
    private static let handledTransitionLimit = 64

    private(set) var state: NotchInteractionState

    init(presentationState: MewsPresentationState) {
        state = NotchInteractionState(presentationState: presentationState)
    }

    mutating func send(_ action: NotchInteractionAction) -> [NotchInteractionEffect] {
        switch action {
        case .logoPrimaryClick:
            return handleLogoPrimaryClick()
        case let .notchClick(isPanelControl):
            return handleNotchClick(isPanelControl: isPanelControl)
        case let .panelSurfaceClick(isPanelControl):
            return handlePanelSurfaceClick(isPanelControl: isPanelControl)
        case .outsideClick:
            return state.visibility == .expanded ? close() : []
        case let .pointerMoved(isInsideNotch, isInsideInteractiveSurface):
            return handlePointerMoved(
                isInsideNotch: isInsideNotch,
                isInsideInteractiveSurface: isInsideInteractiveSurface
            )
        case .hoverOpenTimerFired:
            return handleHoverOpenTimer()
        case .hoverCloseTimerFired:
            return handleHoverCloseTimer()
        case let .notificationPeekTimerFired(sequence):
            return handleNotificationPeekTimer(sequence: sequence)
        case .placementUnavailable:
            return close(preservingStopPulse: false)
        case let .stoppedTransition(identifier):
            return beginTransitionPeek(
                identifier: identifier,
                duration: NotchInteractionTiming.stoppedPulse
            )
        case let .presentationSynchronized(presentationState):
            return synchronizePresentation(presentationState)
        case let .presentationChanged(presentationState):
            return handlePresentationChanged(presentationState)
        }
    }

    private mutating func handleLogoPrimaryClick() -> [NotchInteractionEffect] {
        if state.visibility == .expanded {
            return close()
        }
        return expand(reason: .click)
    }

    private mutating func handleNotchClick(
        isPanelControl: Bool
    ) -> [NotchInteractionEffect] {
        if isPanelControl {
            return state.visibility == .expanded && state.openReason == .hover
                ? expand(reason: .click)
                : []
        }
        if state.visibility != .expanded {
            return expand(reason: .click)
        }
        if state.openReason == .hover {
            return expand(reason: .click)
        }
        return close()
    }

    private mutating func handlePanelSurfaceClick(
        isPanelControl _: Bool
    ) -> [NotchInteractionEffect] {
        guard state.visibility == .expanded,
              state.openReason == .hover else {
            return []
        }
        return expand(reason: .click)
    }

    private mutating func handlePointerMoved(
        isInsideNotch: Bool,
        isInsideInteractiveSurface: Bool
    ) -> [NotchInteractionEffect] {
        let wasInsideNotch = state.pointerInsideNotch
        state.pointerInsideNotch = isInsideNotch
        state.pointerInsideInteractiveSurface = isInsideInteractiveSurface

        var effects = hoverOpenEffects(
            wasInsideNotch: wasInsideNotch,
            isInsideNotch: isInsideNotch
        )
        effects.append(contentsOf: hoverCloseEffects(isInsideSurface: isInsideInteractiveSurface))
        return effects
    }

    private mutating func hoverOpenEffects(
        wasInsideNotch: Bool,
        isInsideNotch: Bool
    ) -> [NotchInteractionEffect] {
        if isInsideNotch && !wasInsideNotch && state.visibility != .expanded {
            state.hoverOpenPending = true
            return [.scheduleHoverOpen(after: NotchInteractionTiming.hoverOpen)]
        }
        if !isInsideNotch && state.hoverOpenPending {
            state.hoverOpenPending = false
            return [.cancelHoverOpen]
        }
        return []
    }

    private mutating func hoverCloseEffects(
        isInsideSurface: Bool
    ) -> [NotchInteractionEffect] {
        guard state.visibility == .expanded, state.openReason == .hover else {
            return cancelHoverCloseIfNeeded()
        }
        if isInsideSurface {
            return cancelHoverCloseIfNeeded()
        }
        guard !state.hoverClosePending else {
            return []
        }
        state.hoverClosePending = true
        return [.scheduleHoverClose(after: NotchInteractionTiming.hoverClose)]
    }

    private mutating func handleHoverOpenTimer() -> [NotchInteractionEffect] {
        guard state.hoverOpenPending else {
            return []
        }
        state.hoverOpenPending = false
        guard state.pointerInsideNotch, state.visibility != .expanded else {
            return []
        }
        return expand(reason: .hover)
    }

    private mutating func handleHoverCloseTimer() -> [NotchInteractionEffect] {
        guard state.hoverClosePending else {
            return []
        }
        state.hoverClosePending = false
        guard state.visibility == .expanded,
              state.openReason == .hover,
              !state.pointerInsideInteractiveSurface else {
            return []
        }
        return close()
    }

    private mutating func handleNotificationPeekTimer(
        sequence: Int
    ) -> [NotchInteractionEffect] {
        guard state.activeNotificationPeekSequence == sequence else {
            return []
        }
        state.activeNotificationPeekSequence = nil
        if state.visibility == .peek,
           state.openReason == .notification {
            state.visibility = .closed
            state.openReason = nil
        }
        return []
    }

    private mutating func handlePresentationChanged(
        _ presentationState: MewsPresentationState
    ) -> [NotchInteractionEffect] {
        guard presentationState != state.presentationState else {
            return []
        }
        state.presentationState = presentationState
        var effects = closeAutomaticPeek()

        switch presentationState.status {
        case .needsInput:
            break
        case .done:
            effects.append(contentsOf: beginTransitionPeek(
                identifier: presentationState.transitionIdentifier,
                duration: NotchInteractionTiming.stoppedPulse
            ))
        case .failed:
            effects.append(contentsOf: beginTransitionPeek(
                identifier: presentationState.transitionIdentifier,
                duration: NotchInteractionTiming.stoppedPulse
            ))
        case .running, .idle:
            break
        }
        return effects
    }

    private mutating func synchronizePresentation(
        _ presentationState: MewsPresentationState
    ) -> [NotchInteractionEffect] {
        if let identifier = presentationState.transitionIdentifier {
            _ = rememberTransition(identifier)
        }
        guard presentationState != state.presentationState else {
            return []
        }
        state.presentationState = presentationState
        if state.visibility == .peek,
           state.openReason == .notification {
            return []
        }
        return closeAutomaticPeek()
    }

    private mutating func beginTransitionPeek(
        identifier: String?,
        duration: TimeInterval
    ) -> [NotchInteractionEffect] {
        guard let identifier, rememberTransition(identifier) else {
            return []
        }
        return beginNotificationPeek(duration: duration)
    }

    private mutating func rememberTransition(_ identifier: String) -> Bool {
        guard state.handledTransitionIdentifiers.insert(identifier).inserted else {
            return false
        }
        state.handledTransitionOrder.append(identifier)
        if state.handledTransitionOrder.count > Self.handledTransitionLimit {
            let oldest = state.handledTransitionOrder.removeFirst()
            state.handledTransitionIdentifiers.remove(oldest)
        }
        return true
    }

    private mutating func beginNotificationPeek(
        duration: TimeInterval?
    ) -> [NotchInteractionEffect] {
        if state.visibility != .expanded {
            state.visibility = .peek
            state.openReason = .notification
        }
        state.nextNotificationPeekSequence += 1

        guard let duration else {
            state.activeNotificationPeekSequence = nil
            return []
        }
        let sequence = state.nextNotificationPeekSequence
        state.activeNotificationPeekSequence = sequence
        return [.scheduleNotificationPeek(sequence: sequence, after: duration)]
    }
}

private extension NotchInteractionModel {
    private mutating func expand(
        reason: NotchOpenReason
    ) -> [NotchInteractionEffect] {
        let effects = cancelPendingTimers()
        state.visibility = .expanded
        state.openReason = reason
        if reason != .hover {
            state.pointerInsideNotch = false
            state.pointerInsideInteractiveSurface = false
        }
        return effects
    }

    private mutating func close(preservingStopPulse: Bool = true) -> [NotchInteractionEffect] {
        var effects = cancelPendingTimers()
        if preservingStopPulse, state.stopPulseActive {
            state.visibility = .peek
            state.openReason = .notification
        } else {
            effects.append(contentsOf: cancelNotificationPeekIfNeeded())
            state.visibility = .closed
            state.openReason = nil
        }
        state.pointerInsideNotch = false
        state.pointerInsideInteractiveSurface = false
        return effects
    }

    private mutating func closeAutomaticPeek() -> [NotchInteractionEffect] {
        guard state.visibility == .peek, state.openReason == .notification else {
            return []
        }
        let effects = cancelNotificationPeekIfNeeded()
        state.visibility = .closed
        state.openReason = nil
        return effects
    }

    private mutating func cancelPendingTimers() -> [NotchInteractionEffect] {
        var effects: [NotchInteractionEffect] = []
        if state.hoverOpenPending {
            state.hoverOpenPending = false
            effects.append(.cancelHoverOpen)
        }
        effects.append(contentsOf: cancelHoverCloseIfNeeded())
        return effects
    }

    private mutating func cancelHoverCloseIfNeeded() -> [NotchInteractionEffect] {
        guard state.hoverClosePending else {
            return []
        }
        state.hoverClosePending = false
        return [.cancelHoverClose]
    }

    private mutating func cancelNotificationPeekIfNeeded() -> [NotchInteractionEffect] {
        guard state.activeNotificationPeekSequence != nil else {
            return []
        }
        state.activeNotificationPeekSequence = nil
        return [.cancelNotificationPeek]
    }
}
