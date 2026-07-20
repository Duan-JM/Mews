import AppKit
import Foundation

struct OverlayInsets: Equatable {
    let top: CGFloat
    let left: CGFloat
    let bottom: CGFloat
    let right: CGFloat
}

struct ScreenSnapshot: Equatable {
    let id: String
    let frame: CGRect
    let visibleFrame: CGRect
    let safeAreaInsets: OverlayInsets
    let auxiliaryTopLeftArea: CGRect?
    let auxiliaryTopRightArea: CGRect?
    let isMain: Bool

    var notchFrame: CGRect? {
        guard safeAreaInsets.top > 0,
              let auxiliaryTopLeftArea,
              let auxiliaryTopRightArea else {
            return nil
        }

        let topArea = CGRect(
            x: frame.minX,
            y: frame.maxY - safeAreaInsets.top,
            width: frame.width,
            height: safeAreaInsets.top
        )
        let leftArea = auxiliaryTopLeftArea.intersection(topArea)
        let rightArea = auxiliaryTopRightArea.intersection(topArea)
        guard !leftArea.isNull,
              !rightArea.isNull,
              leftArea.width > 0,
              rightArea.width > 0,
              leftArea.maxX < rightArea.minX else {
            return nil
        }

        return CGRect(
            x: leftArea.maxX,
            y: topArea.minY,
            width: rightArea.minX - leftArea.maxX,
            height: topArea.height
        )
    }
}

extension ScreenSnapshot {
    init(screen: NSScreen, isMain: Bool) {
        let insets = screen.safeAreaInsets
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        let screenNumber = screen.deviceDescription[screenNumberKey] as? NSNumber

        self.init(
            id: screenNumber?.stringValue ?? screen.localizedName,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaInsets: OverlayInsets(
                top: insets.top,
                left: insets.left,
                bottom: insets.bottom,
                right: insets.right
            ),
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
            isMain: isMain
        )
    }

    static func currentScreens() -> [ScreenSnapshot] {
        let mainScreen = NSScreen.main
        return NSScreen.screens.map { screen in
            ScreenSnapshot(screen: screen, isMain: screen === mainScreen)
        }
    }
}

enum OverlayPlacementMode: Equatable {
    case notch
    case topCenter
}

struct OverlayTarget: Equatable {
    let screen: ScreenSnapshot
    let mode: OverlayPlacementMode
    let anchorFrame: CGRect
}

struct OverlayScreenResolver {
    func resolve(screens: [ScreenSnapshot]) -> OverlayTarget? {
        if let screen = screens.first(where: { $0.notchFrame != nil }),
           let notchFrame = screen.notchFrame {
            return OverlayTarget(screen: screen, mode: .notch, anchorFrame: notchFrame)
        }
        if let screen = screens.first(where: \.isMain) {
            return topCenterTarget(screen: screen)
        }
        guard let screen = screens.first else {
            return nil
        }
        return topCenterTarget(screen: screen)
    }

    private func topCenterTarget(screen: ScreenSnapshot) -> OverlayTarget {
        let topCenter = CGPoint(x: screen.frame.midX, y: screen.visibleFrame.maxY)
        return OverlayTarget(
            screen: screen,
            mode: .topCenter,
            anchorFrame: CGRect(origin: topCenter, size: .zero)
        )
    }
}

struct OverlayPlacement: Equatable {
    let screenID: String
    let mode: OverlayPlacementMode
    let frame: CGRect
}

struct OverlayPlacementCalculator {
    static let maximumSize = CGSize(width: 420, height: 220)
    static let horizontalMargin: CGFloat = 24

    func placement(for target: OverlayTarget) -> OverlayPlacement {
        let screen = target.screen
        let horizontalBounds = screen.visibleFrame.insetBy(
            dx: Self.horizontalMargin,
            dy: 0
        )
        let width = min(Self.maximumSize.width, max(0, horizontalBounds.width))
        let centeredX = target.anchorFrame.midX - (width / 2)
        let maximumX = horizontalBounds.maxX - width
        let originX = min(max(centeredX, horizontalBounds.minX), maximumX)
        let frame = CGRect(
            x: originX,
            y: target.anchorFrame.maxY - Self.maximumSize.height,
            width: width,
            height: Self.maximumSize.height
        )
        return OverlayPlacement(screenID: screen.id, mode: target.mode, frame: frame)
    }
}
