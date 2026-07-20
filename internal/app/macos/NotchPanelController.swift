import AppKit
import Foundation

final class NotchPanelController {
    typealias ScreenProvider = () -> [ScreenSnapshot]

    let panel: NSPanel
    private(set) var placement: OverlayPlacement?

    private let notificationCenter: NotificationCenter
    private let screenProvider: ScreenProvider
    private let resolver = OverlayScreenResolver()
    private let calculator = OverlayPlacementCalculator()
    private var screenObserver: NSObjectProtocol?

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

        configurePanel()
        reposition()
        screenObserver = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reposition()
        }
    }

    deinit {
        if let screenObserver {
            notificationCenter.removeObserver(screenObserver)
        }
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
        panel.ignoresMouseEvents = isClosed
        if isClosed {
            panel.orderOut(nil)
        }
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
