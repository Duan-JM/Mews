import AppKit
import Foundation
import SwiftUI

@MainActor
final class NotchPanelController: NSObject {
    typealias ScreenProvider = () -> [ScreenSnapshot]
    typealias OpenContextHandler = (CLIContextPayload, SessionIdentity?) -> Void
    typealias CopyCommandHandler = (String) -> Void
    typealias HideSessionHandler = SessionListPresentationModel.HideHandler

    let panel: NSPanel
    private(set) var placement: OverlayPlacement?
    var canPresentNotchAlert: Bool {
        placement?.mode == .notch
    }

    private let notificationCenter: NotificationCenter
    private let screenChangeNotification: Notification.Name
    private let screenProvider: ScreenProvider
    private let onOpenContext: OpenContextHandler
    private let onCopyCommand: CopyCommandHandler
    private let onHideSession: HideSessionHandler
    private let log: (String) -> Void
    private var onPlacementUnavailable: () -> Void = {}
    private let resolver = OverlayScreenResolver()
    private let calculator = OverlayPlacementCalculator()
    private let shellModel = NotchShellViewModel()
    private var content = NotchPanelContent.empty
    private var canonicalContent = NotchPanelContent.empty
    private var interactionState = NotchInteractionState(
        presentationState: MewsPresentationState(event: nil)
    )
    private var accessibilityPreferences = NotchAccessibilityPreferences(
        reduceMotion: false,
        reduceTransparency: false,
        increaseContrast: false
    )
    private lazy var sessionListModel = SessionListPresentationModel(
        hide: onHideSession,
        log: log,
        announce: { [weak self] message in
            self?.announceAccessibility(message)
        }
    )

    private lazy var hostingView = NotchHostingView(
        rootView: NotchShellView(
            model: shellModel,
            sessionListModel: sessionListModel,
            onReturnToCLI: onOpenContext,
            onCopyCommand: onCopyCommand
        )
    )

    init(
        notificationCenter: NotificationCenter = .default,
        screenChangeNotification: Notification.Name? = nil,
        screenProvider: @escaping ScreenProvider = ScreenSnapshot.currentScreens,
        onOpenContext: @escaping OpenContextHandler = { _, _ in },
        onCopyCommand: @escaping CopyCommandHandler = { _ in },
        onHideSession: @escaping HideSessionHandler = { _, completion in
            completion(.failure(NotchPanelControllerError.dismissalUnavailable))
        },
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.notificationCenter = notificationCenter
        self.screenChangeNotification =
            screenChangeNotification ?? NSApplication.didChangeScreenParametersNotification
        self.screenProvider = screenProvider
        self.onOpenContext = onOpenContext
        self.onCopyCommand = onCopyCommand
        self.onHideSession = onHideSession
        self.log = log
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: OverlayPlacementCalculator.maximumSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()
        configurePanel()
        reposition()
        notificationCenter.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: self.screenChangeNotification,
            object: nil
        )
    }

    deinit {
        notificationCenter.removeObserver(
            self,
            name: screenChangeNotification,
            object: nil
        )
    }

    @discardableResult
    func reposition() -> OverlayPlacement? {
        guard let target = resolver.resolve(screens: screenProvider()) else {
            placement = nil
            interactionState = NotchInteractionState(
                presentationState: interactionState.presentationState
            )
            content = canonicalContent
            sessionListModel.update(
                canonicalRows: canonicalContent.sessionRows,
                revision: canonicalContent.sessionRevision
            )
            panel.hasShadow = false
            sessionListModel.cancelForLifecycle()
            panel.orderOut(nil)
            refreshShell()
            onPlacementUnavailable()
            return nil
        }
        let placement = calculator.placement(for: target)
        panel.setFrame(placement.frame, display: false)
        self.placement = placement
        refreshShell()
        applyWindowPresentation()
        return placement
    }

    func update(
        interactionState: NotchInteractionState,
        accessibilityPreferences: NotchAccessibilityPreferences
    ) {
        let wasExpanded = self.interactionState.visibility == .expanded
        self.interactionState = interactionState
        self.accessibilityPreferences = accessibilityPreferences
        sessionListModel.updateAccessibility(
            reduceMotion: accessibilityPreferences.reduceMotion
        )
        if wasExpanded && interactionState.visibility != .expanded {
            content = canonicalContent
            sessionListModel.update(
                canonicalRows: canonicalContent.sessionRows,
                revision: canonicalContent.sessionRevision
            )
            sessionListModel.cancelForLifecycle()
        }
        refreshShell()
        applyWindowPresentation()
    }

    func update(content: NotchPanelContent) {
        canonicalContent = content
        let presentedContent = interactionState.visibility == .expanded
            ? content.stabilized(relativeTo: self.content)
            : content
        sessionListModel.update(
            canonicalRows: presentedContent.sessionRows,
            revision: presentedContent.sessionRevision
        )
        guard self.content != presentedContent else {
            return
        }
        self.content = presentedContent
        refreshShell()
    }

    func hide() {
        sessionListModel.cancelForLifecycle()
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        reposition()
    }

    private func configurePanel() {
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [
            .fullScreenAuxiliary,
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle
        ]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        panel.contentView = hostingView
        hostingView.frame = CGRect(origin: .zero, size: panel.frame.size)
        hostingView.autoresizingMask = [.width, .height]
    }

    private func refreshShell() {
        let placementMode = placement?.mode ?? .topCenter
        let panelSize = placement?.frame.size ?? panel.frame.size
        let anchorSize = placement?.anchorFrame.size ?? .zero
        shellModel.update(
            snapshot: NotchShellSnapshot(
                visibility: interactionState.visibility,
                placementMode: placementMode,
                panelSize: panelSize,
                anchorSize: anchorSize,
                presentationState: interactionState.presentationState,
                content: content,
                transitionStyle: .resolved(
                    reduceMotion: accessibilityPreferences.reduceMotion
                ),
                reduceTransparency: accessibilityPreferences.reduceTransparency,
                increaseContrast: accessibilityPreferences.increaseContrast
            )
        )
        panel.setAccessibilityLabel(
            "\(interactionState.presentationState.accessibilityLabel), " +
                "\(interactionState.visibility.accessibilityDescription)"
        )
    }

    private func applyWindowPresentation() {
        guard let placement else {
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
            return
        }
        panel.hasShadow = placement.mode == .topCenter
        let isVisible = NotchPanelPresentationPolicy.isVisible(
            visibility: interactionState.visibility,
            placementMode: placement.mode
        )
        guard isVisible else {
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
            return
        }

        panel.ignoresMouseEvents = !NotchPanelPresentationPolicy.acceptsMouseEvents(
            visibility: interactionState.visibility
        )
        panel.orderFrontRegardless()
    }

    private func shellGeometry(
        visibility: NotchVisibility
    ) -> NotchShellGeometry {
        return NotchShellGeometry.resolved(
            snapshot: shellModel.snapshot,
            visibility: visibility
        )
    }

    private func announceAccessibility(_ message: String) {
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}

extension NotchPanelController {
    func setPlacementUnavailableHandler(
        _ handler: @escaping () -> Void
    ) {
        onPlacementUnavailable = handler
    }

    var sessionListSnapshot: SessionListPresentationSnapshot {
        return sessionListModel.snapshot
    }

    var sessionSwipeInputRouter: SessionSwipeInputRouter {
        return sessionListModel.inputRouter
    }

    func prepareForPanelInteraction(
        event: NSEvent,
        targetsControl: Bool
    ) {
        if let target = sessionListModel.inputRouter.inputTarget(for: event) {
            sessionListModel.prepareForInputTarget(target.request)
        } else if !targetsControl {
            sessionListModel.closeRevealedRow()
        }
    }

    func eventTargetsControl(_ event: NSEvent) -> Bool {
        guard event.window === panel,
              let contentView = panel.contentView else {
            return false
        }
        let point = contentView.convert(event.locationInWindow, from: nil)
        var view = contentView.hitTest(point)
        while let current = view {
            if current is NSControl {
                return true
            }
            view = current.superview
        }
        return false
    }

    func containsNotchTrigger(_ point: CGPoint) -> Bool {
        guard let placement, placement.mode == .notch else {
            return false
        }
        let visibility = interactionState.visibility == .expanded
            ? NotchVisibility.closed
            : interactionState.visibility
        return shellGeometry(visibility: visibility).contains(
            point,
            in: placement.frame
        )
    }

    func containsVisibleShell(_ point: CGPoint) -> Bool {
        guard let placement,
              NotchPanelPresentationPolicy.isVisible(
                  visibility: interactionState.visibility,
                  placementMode: placement.mode
              ) else {
            return false
        }
        return shellGeometry(visibility: interactionState.visibility).contains(
            point,
            in: placement.frame
        )
    }
}

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        // Custom SwiftUI button styles need explicit click-through on non-key panels on macOS 13-14.
        return true
    }
}

private extension NotchVisibility {
    var accessibilityDescription: String {
        switch self {
        case .closed:
            return "compact status"
        case .peek:
            return "status preview"
        case .expanded:
            return "panel expanded"
        }
    }
}

private enum NotchPanelControllerError: Error {
    case dismissalUnavailable
}
