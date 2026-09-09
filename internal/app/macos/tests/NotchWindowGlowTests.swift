import AppKit
import SwiftUI

extension MewsAppModelTests {
    static func testNotchWindowGlow() throws {
        var failures: [String] = []
        for scale: CGFloat in [1, 2] {
            try checkNotchBacking(scale: scale, failures: &failures)
            try checkOpenTopGlow(scale: scale, failures: &failures)
            for mode in [OverlayPlacementMode.notch, .topCenter] {
                for status in [SessionStatus.running, .needsInput, .done] {
                    try checkWindowGlow(
                        snapshot: windowGlowSnapshot(visibility: .expanded, mode: mode, status: status),
                        scale: scale, failures: &failures
                    )
                }
            }
        }
        guard failures.isEmpty else {
            throw NotchWindowGlowFailure(message: failures.joined(separator: "\n"))
        }
        print("Notch window: independent hardware backing, open top, and native halo bounds passed at 1x/2x")
    }

    private static func checkNotchBacking(scale: CGFloat, failures: inout [String]) throws {
        for hardwareHeight: CGFloat in [26, 32] {
            for radius: CGFloat in [4, 12] {
                let snapshot = windowGlowSnapshot(visibility: .closed)
                let host = NSHostingView(rootView:
                    ZStack(alignment: .top) {
                        NotchShellView(
                            model: NotchShellViewModel(snapshot: snapshot),
                            sessionListModel: SessionListPresentationModel { _, _ in }
                        )
                        RoundedRectangle(cornerRadius: radius, style: .circular)
                            .fill(Color.black)
                            .overlay(alignment: .top) { Color.black.frame(height: radius) }
                            .frame(width: 179, height: hardwareHeight)
                    }
                    .padding(40)
                    .background(Color.white)
                    .environment(\.displayScale, scale)
                )
                let raster = try NotchWindowRaster.capture(
                    host, size: CGSize(width: 500, height: 300), scale: scale
                )
                for point in [CGPoint(x: 250, y: 70), CGPoint(x: 162, y: 70), CGPoint(x: 338, y: 70)]
                    where raster.brightness(at: point) > 20 {
                    failures.append("backing \(hardwareHeight)/\(radius) at \(scale)x: exposed gap at \(point)")
                }
            }
        }
    }

    private static func checkOpenTopGlow(scale: CGFloat, failures: inout [String]) throws {
        let snapshot = windowGlowSnapshot(visibility: .expanded)
        let host = NSHostingView(rootView:
            NotchShellView(
                model: NotchShellViewModel(snapshot: snapshot),
                sessionListModel: SessionListPresentationModel { _, _ in }
            )
            .padding(40)
            .background(Color.black)
            .environment(\.displayScale, scale)
        )
        let raster = try NotchWindowRaster.capture(
            host, size: CGSize(width: 500, height: 300), scale: scale
        )
        if raster.colorScore(at: CGPoint(x: 100, y: 40)) > 10 {
            failures.append("expanded \(scale)x: unwanted colored top edge")
        }
        if raster.colorScore(at: CGPoint(x: 38, y: 150)) < 5 ||
            raster.colorScore(at: CGPoint(x: 250, y: 264)) < 5 {
            failures.append("expanded \(scale)x: missing positive side/bottom glow control")
        }
    }

    private static func checkWindowGlow(
        snapshot: NotchShellSnapshot, scale: CGFloat, failures: inout [String]
    ) throws {
        var screens = [windowGlowScreen(mode: snapshot.placementMode)]
        let controller = NotchPanelController(screenProvider: { screens })
        defer { controller.hide() }
        showWindowGlow(controller, snapshot: snapshot)
        let glowPanel = controller.panel.childWindows?.first ?? controller.panel
        guard let placement = controller.placement, let host = glowPanel.contentView else {
            throw NotchWindowGlowFailure(message: "missing real panel content")
        }
        let window = glowPanel.frame
        if !glowPanel.ignoresMouseEvents || controller.panel.frame.size != placement.frame.size {
            failures.append("native \(scale)x: halo must not enlarge the input window")
        }
        let shell = controller.panel.frame
        let probes = [
            CGPoint(x: shell.minX - 6, y: shell.midY),
            CGPoint(x: shell.maxX + 6, y: shell.midY),
            CGPoint(x: shell.midX, y: shell.minY - 6)
        ]
        let raster = try NotchWindowRaster.capture(host, size: window.size, scale: scale)
        for point in probes {
            if !window.contains(point) {
                failures.append("native \(scale)x: window clips halo at \(point)")
                continue
            }
            let localPoint = CGPoint(x: point.x - window.minX, y: window.maxY - point.y)
            if raster.colorScore(at: localPoint) < 3 {
                failures.append("native \(scale)x: missing halo at \(point)")
            }
            if controller.containsVisibleShell(point) {
                failures.append("native \(scale)x: transparent halo intercepts clicks")
            }
        }
        if !controller.containsVisibleShell(CGPoint(x: shell.midX, y: shell.minY + 30)) {
            failures.append("native \(scale)x: actual shell must remain interactive")
        }
        controller.hide()
        if glowPanel.isVisible {
            failures.append("native \(scale)x: hiding must remove the passive glow")
        }
        showWindowGlow(controller, snapshot: snapshot)
        if controller.panel.childWindows?.contains(where: { $0 === glowPanel }) != true || !glowPanel.isVisible {
            failures.append("native \(scale)x: reopening must reattach the passive glow")
        }
        screens = []
        controller.reposition()
        if controller.panel.isVisible || glowPanel.isVisible {
            failures.append("native \(scale)x: screen loss must hide both windows")
        }
    }

    private static func showWindowGlow(_ controller: NotchPanelController, snapshot: NotchShellSnapshot) {
        controller.update(content: snapshot.content)
        controller.update(
            interactionState: NotchInteractionState(
                visibility: .expanded, openReason: .click, presentationState: snapshot.presentationState
            ),
            accessibilityPreferences: NotchAccessibilityPreferences(
                reduceMotion: true, reduceTransparency: false, increaseContrast: false
            )
        )
    }

    private static func windowGlowSnapshot(
        visibility: NotchVisibility,
        mode: OverlayPlacementMode = .notch,
        status: SessionStatus = .running
    ) -> NotchShellSnapshot {
        return NotchShellSnapshot(
            visibility: visibility, placementMode: mode,
            panelSize: CGSize(width: 420, height: 220),
            anchorSize: CGSize(width: 179, height: 32),
            presentationState: MewsPresentationState(event: nil),
            content: NotchPanelContent(
                presentation: SessionPresentation(rows: [], aggregateStatuses: [status], health: nil),
                events: [], currentEvent: nil
            ),
            transitionStyle: .opacityOnly, reduceTransparency: false, increaseContrast: false
        )
    }

    private static func windowGlowScreen(mode: OverlayPlacementMode) -> ScreenSnapshot {
        return ScreenSnapshot(
            id: "glow-fixture", frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 924),
            safeAreaInsets: OverlayInsets(top: mode == .notch ? 32 : 0, left: 0, bottom: 0, right: 0),
            auxiliaryTopLeftArea: mode == .notch ? CGRect(x: 0, y: 924, width: 646, height: 32) : nil,
            auxiliaryTopRightArea: mode == .notch ? CGRect(x: 825, y: 924, width: 645, height: 32) : nil,
            isMain: true
        )
    }
}

@MainActor
private struct NotchWindowRaster {
    let bitmap: NSBitmapImageRep
    let scale: CGFloat

    static func capture(_ host: NSView, size: CGSize, scale: CGFloat) throws -> NotchWindowRaster {
        _ = NSApplication.shared
        host.frame.size = size
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            throw NotchWindowGlowFailure(message: "could not allocate window capture")
        }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return NotchWindowRaster(bitmap: bitmap, scale: scale)
    }

    func brightness(at point: CGPoint) -> Int {
        let color = pixel(at: point)
        return max(color.red, color.green, color.blue)
    }

    func colorScore(at point: CGPoint) -> Int {
        let color = pixel(at: point)
        return abs(color.red - color.green)
    }

    private func pixel(at point: CGPoint) -> NotchRasterPixel {
        let column = Int(point.x * scale)
        let row = Int(point.y * scale)
        precondition(column >= 0 && row >= 0 && column < bitmap.pixelsWide && row < bitmap.pixelsHigh)
        guard let pixels = bitmap.bitmapData else {
            preconditionFailure("window capture has no pixels")
        }
        let pixel = pixels + row * bitmap.bytesPerRow + column * 4
        return NotchRasterPixel(red: Int(pixel[0]), green: Int(pixel[1]), blue: Int(pixel[2]))
    }
}

private struct NotchRasterPixel {
    let red: Int
    let green: Int
    let blue: Int
}

private struct NotchWindowGlowFailure: Error {
    let message: String
}
