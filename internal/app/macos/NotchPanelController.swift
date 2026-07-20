import AppKit
import Foundation

@MainActor
final class NotchPanelController: NSObject {
    typealias ScreenProvider = () -> [ScreenSnapshot]

    let panel: NSPanel
    private(set) var placement: OverlayPlacement?

    private let notificationCenter: NotificationCenter
    private let screenProvider: ScreenProvider
    private let resolver = OverlayScreenResolver()
    private let calculator = OverlayPlacementCalculator()

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
            return nil
        }
        let placement = calculator.placement(for: target)
        panel.setFrame(placement.frame, display: false)
        self.placement = placement
        return placement
    }

    func setClosed(_ isClosed: Bool) {
        if isClosed {
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        } else {
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
        }
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
        panel.ignoresMouseEvents = true
    }
}
