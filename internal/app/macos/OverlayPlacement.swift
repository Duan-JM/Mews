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

struct FullscreenWindowSnapshot: Equatable {
    let ownerProcessID: Int32
    let layer: Int
    let bounds: CGRect
}

struct FullscreenCoverDetector {
    @MainActor
    func isActive(onScreenID screenID: String?) -> Bool {
        guard let screenID,
              let application = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let windows = windowInfo.compactMap { window -> FullscreenWindowSnapshot? in
            guard let ownerProcessID =
                    (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else {
                return nil
            }
            return FullscreenWindowSnapshot(
                ownerProcessID: ownerProcessID,
                layer: layer,
                bounds: bounds
            )
        }
        return isActive(
            frontmostProcessID: application.processIdentifier,
            windows: windows,
            screens: ScreenSnapshot.currentScreens(),
            screenID: screenID
        )
    }

    func isActive(
        frontmostProcessID: Int32?,
        windows: [FullscreenWindowSnapshot],
        screens: [ScreenSnapshot],
        screenID: String
    ) -> Bool {
        guard let frontmostProcessID,
              let referenceTop = screens.first(where: \.isMain)?.frame.maxY ??
                screens.map(\.frame.maxY).max(),
              let screen = screens.first(where: { $0.id == screenID }) else {
            return false
        }
        let foregroundWindows = windows.filter {
            $0.ownerProcessID == frontmostProcessID
        }
        let quartzFrame = CGRect(
            x: screen.frame.minX,
            y: referenceTop - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
        let topInset = max(
            screen.frame.maxY - screen.visibleFrame.maxY,
            screen.safeAreaInsets.top
        )
        return foregroundWindows.contains { window in
            coversFullScreen(window.bounds, screen: quartzFrame) ||
                coversTopEdge(
                    window,
                    screen: quartzFrame,
                    topInset: topInset
                )
        }
    }

    private func coversFullScreen(
        _ window: CGRect,
        screen: CGRect
    ) -> Bool {
        return spansWidth(window, screen: screen) &&
            abs(window.minY - screen.minY) <= 2 &&
            window.maxY >= screen.maxY - 2
    }

    private func coversTopEdge(
        _ window: FullscreenWindowSnapshot,
        screen: CGRect,
        topInset: CGFloat
    ) -> Bool {
        guard window.layer > 0, topInset > 0 else {
            return false
        }
        return spansWidth(window.bounds, screen: screen) &&
            abs(window.bounds.minY - screen.minY) <= 2 &&
            window.bounds.height >= topInset - 2
    }

    private func spansWidth(
        _ window: CGRect,
        screen: CGRect
    ) -> Bool {
        return window.minX <= screen.minX + 2 &&
            window.maxX >= screen.maxX - 2
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
    let anchorFrame: CGRect
    let frame: CGRect

    func containsPhysicalNotch(_ point: CGPoint) -> Bool {
        return mode == .notch && anchorFrame.contains(point)
    }

    func containsPanel(_ point: CGPoint) -> Bool {
        return frame.contains(point)
    }

    func containsInteractiveSurface(_ point: CGPoint) -> Bool {
        return containsPhysicalNotch(point) || containsPanel(point)
    }
}

struct OverlayPlacementCalculator {
    static let maximumSize = CGSize(width: 420, height: 220)
    static let horizontalMargin: CGFloat = 24
    static let topCenterGap: CGFloat = 6

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
        let verticalGap = target.mode == .topCenter ? Self.topCenterGap : 0
        let frame = CGRect(
            x: originX,
            y: target.anchorFrame.maxY - Self.maximumSize.height - verticalGap,
            width: width,
            height: Self.maximumSize.height
        )
        return OverlayPlacement(
            screenID: screen.id,
            mode: target.mode,
            anchorFrame: target.anchorFrame,
            frame: frame
        )
    }
}
