import AppKit
import Foundation
import SwiftUI

@MainActor
final class NotchPanelController: NSObject {
    typealias ScreenProvider = () -> [ScreenSnapshot]

    let panel: NSPanel
    private(set) var placement: OverlayPlacement?

    private let notificationCenter: NotificationCenter
    private let screenProvider: ScreenProvider
    private let resolver = OverlayScreenResolver()
    private let calculator = OverlayPlacementCalculator()
    private let shellModel = NotchShellViewModel()
    private var interactionState = NotchInteractionState(
        presentationState: MewsPresentationState(event: nil)
    )
    private var reduceMotion = false

    private lazy var hostingView = NSHostingView(
        rootView: NotchShellView(model: shellModel)
    )

    init(
        notificationCenter: NotificationCenter = .default,
        screenProvider: @escaping ScreenProvider = ScreenSnapshot.currentScreens
    ) {
        self.notificationCenter = notificationCenter
        self.screenProvider = screenProvider
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
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        notificationCenter.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @discardableResult
    func reposition() -> OverlayPlacement? {
        guard let target = resolver.resolve(screens: screenProvider()) else {
            placement = nil
            panel.orderOut(nil)
            refreshShell()
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
        reduceMotion: Bool
    ) {
        self.interactionState = interactionState
        self.reduceMotion = reduceMotion
        refreshShell()
        applyWindowPresentation()
    }

    func hide() {
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
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
                transitionStyle: .resolved(reduceMotion: reduceMotion)
            )
        )
        panel.setAccessibilityLabel(
            "\(interactionState.presentationState.accessibilityLabel), " +
                "\(interactionState.visibility.accessibilityDescription)"
        )
    }

    private func applyWindowPresentation() {
        guard let placement else {
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
            return
        }
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
}

private extension NotchVisibility {
    var accessibilityDescription: String {
        switch self {
        case .closed:
            return "panel closed"
        case .peek:
            return "panel preview"
        case .expanded:
            return "panel expanded"
        }
    }
}
