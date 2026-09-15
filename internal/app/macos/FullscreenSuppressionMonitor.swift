import Foundation

@MainActor
final class FullscreenSuppressionMonitor: NSObject {
    private static let refreshInterval: TimeInterval = 0.1

    private weak var panelController: NotchPanelController?
    private var timer: Timer?
    private let detector = FullscreenCoverDetector()

    func start(panelController: NotchPanelController?) {
        stop()
        self.panelController = panelController
        refresh()
        let timer = Timer(
            timeInterval: Self.refreshInterval,
            target: self,
            selector: #selector(timerDidFire(_:)),
            userInfo: nil,
            repeats: true
        )
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        panelController = nil
    }

    @objc private func timerDidFire(_ timer: Timer) {
        refresh()
    }

    private func refresh() {
        panelController?.setFullscreenSuppressed(
            detector.isActive(onScreenID: panelController?.placement?.screenID)
        )
    }
}
