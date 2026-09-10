import AppKit
import SwiftUI

extension MewsAppModelTests {
    static func testNotchWindowGlow() throws {
        var failures: [String] = []
        for scale: CGFloat in [1, 2] {
            try checkNotchBacking(scale: scale, failures: &failures)
            try checkOpenTopGlow(scale: scale, failures: &failures)
            try checkWindowMotion(scale: scale)
            for mode in [OverlayPlacementMode.notch, .topCenter] {
                for status in [SessionStatus.running, .needsInput, .done] {
                    try checkWindowGlow(
                        snapshot: windowGlowSnapshot(visibility: .expanded, mode: mode, status: status),
                        scale: scale, failures: &failures
                    )
                }
            }
            try checkWindowGlow(
                snapshot: windowGlowSnapshot(
                    visibility: .expanded,
                    mode: .notch,
                    status: nil
                ),
                scale: scale,
                failures: &failures
            )
            for preferences in [(true, false, false), (false, true, false), (false, false, true)] {
                try checkWindowGlow(
                    snapshot: windowGlowSnapshot(
                        visibility: .expanded, mode: .topCenter, status: .needsInput,
                        reduceMotion: preferences.0, reduceTransparency: preferences.1,
                        increaseContrast: preferences.2
                    ),
                    scale: scale, failures: &failures
                )
            }
        }
        guard failures.isEmpty else {
            throw NotchWindowGlowFailure(message: failures.joined(separator: "\n"))
        }
        print("Notch window: independent hardware backing, open top, and native halo bounds passed at 1x/2x")
    }

    private static func checkWindowMotion(scale: CGFloat) throws {
        for reduceMotion in [false, true] {
            var time: TimeInterval = 0
            let controller = NotchPanelController(
                screenProvider: { [windowGlowScreen(mode: .notch)] },
                prefersDisplayLink: false,
                animationClock: { time }
            )
            defer { controller.hide() }
            controller.update(content: windowGlowSnapshot(visibility: .closed).content)
            let probe = NotchWindowMotionProbe(
                controller: controller, scale: scale, reduceMotion: reduceMotion,
                advanceClock: { time += 1.0 / 60 }
            )
            probe.show(.closed)
            try probe.sample(until: 32, expectsMotion: false)
            guard !controller.revealsPhysicalContent else {
                throw NotchWindowGlowFailure(
                    message: "collapsed physical-notch content must stay hidden with Reduce Motion"
                )
            }
            probe.show(.expanded)
            if scale == 2 {
                // A slow renderer must not advance the frame being tested.
                Thread.sleep(forTimeInterval: 0.35)
            }
            try probe.sample(until: 220, expectsMotion: !reduceMotion)
            probe.show(.closed)
            try probe.sample(until: 32, expectsMotion: !reduceMotion)
            if !reduceMotion {
                controller.update(content: windowGlowSnapshot(visibility: .closed, status: .needsInput).content)
                probe.show(.expanded)
                try probe.sample(until: 100, expectsMotion: true, crossesHeight: true)
                probe.show(.closed)
                try probe.sample(until: 32, expectsMotion: true)
                probe.show(.expanded)
                try probe.sample(until: 100, expectsMotion: true, crossesHeight: true)
                let reduced = NotchWindowMotionProbe(
                    controller: controller, scale: scale, reduceMotion: true, advanceClock: probe.advanceClock
                )
                reduced.show(.expanded)
                try reduced.sample(until: 220, expectsMotion: false)
            }
        }
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

    static func showWindowGlow(_ controller: NotchPanelController, snapshot: NotchShellSnapshot) {
        controller.update(content: snapshot.content)
        controller.update(
            interactionState: NotchInteractionState(
                visibility: .expanded, openReason: .click,
                presentationState: snapshot.presentationState
            ),
            accessibilityPreferences: NotchAccessibilityPreferences(
                reduceMotion: snapshot.transitionStyle == .opacityOnly,
                reduceTransparency: snapshot.reduceTransparency,
                increaseContrast: snapshot.increaseContrast
            )
        )
    }

    private static func windowGlowSnapshot(
        visibility: NotchVisibility,
        mode: OverlayPlacementMode = .notch,
        status: SessionStatus? = .running,
        reduceMotion: Bool = true,
        reduceTransparency: Bool = false,
        increaseContrast: Bool = false
    ) -> NotchShellSnapshot {
        return NotchShellSnapshot(
            visibility: visibility, placementMode: mode,
            panelSize: CGSize(width: 420, height: 220),
            anchorSize: CGSize(width: 179, height: 32),
            presentationState: MewsPresentationState(event: nil),
            content: NotchPanelContent(
                presentation: SessionPresentation(
                    rows: [],
                    aggregateStatuses: status.map { [$0] } ?? [],
                    health: nil
                ),
                events: [], currentEvent: nil
            ),
            transitionStyle: reduceMotion ? .opacityOnly : .spatial,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }

    static func windowGlowScreen(mode: OverlayPlacementMode) -> ScreenSnapshot {
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
struct NotchWindowRaster {
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

    static func captureLayer(
        _ host: NSView,
        size: CGSize,
        scale: CGFloat
    ) throws -> NotchWindowRaster {
        host.frame.size = size
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NotchWindowGlowFailure(message: "could not allocate layer capture")
        }
        bitmap.size = size
        context.cgContext.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
        context.cgContext.scaleBy(x: scale, y: -scale)
        host.layer?.render(in: context.cgContext)
        return NotchWindowRaster(bitmap: bitmap, scale: scale)
    }

    func brightness(at point: CGPoint) -> Int {
        let color = pixel(at: point)
        return max(color.red, color.green, color.blue)
    }

    func alpha(at point: CGPoint) -> Int {
        let column = Int(point.x * scale)
        let row = Int(point.y * scale)
        guard let pixels = bitmap.bitmapData else { return 0 }
        return Int((pixels + row * bitmap.bytesPerRow + column * 4)[3])
    }

    func colorScore(at point: CGPoint) -> Int {
        let color = pixel(at: point)
        return abs(color.red - color.green)
    }

    func motionEdges(glow: Bool) throws -> [Double] {
        guard let pixels = bitmap.bitmapData else {
            throw NotchWindowGlowFailure(message: "motion capture has no pixels")
        }
        func score(column: Int, row: Int) -> Int {
            let pixel = pixels + row * bitmap.bytesPerRow + column * 4
            if glow {
                return Int(max(pixel[0], pixel[1], pixel[2])) -
                    Int(min(pixel[0], pixel[1], pixel[2]))
            }
            return max(pixel[0], pixel[1], pixel[2]) <= 20 ? Int(pixel[3]) : 0
        }
        let horizontal = (0..<bitmap.pixelsWide).map { score(column: $0, row: Int(4 * scale)) }
        let vertical = (0..<bitmap.pixelsHigh).map { score(column: bitmap.pixelsWide / 2, row: $0) }
        let middle = bitmap.pixelsWide / 2
        if glow {
            return try [
                peakCenter(horizontal[..<middle]) - NotchGlowPanel.margin * scale,
                peakCenter(horizontal[middle...]) - NotchGlowPanel.margin * scale,
                peakCenter(vertical[...])
            ]
        }
        guard let left = horizontal.firstIndex(where: { $0 >= 128 }),
              let right = horizontal.lastIndex(where: { $0 >= 128 }),
              let bottom = vertical.lastIndex(where: { $0 >= 128 }) else {
            throw NotchWindowGlowFailure(
                message: "motion capture must contain an opaque backing; " +
                    "horizontal max \(horizontal.max() ?? -1), vertical max \(vertical.max() ?? -1)"
            )
        }
        return [Double(left), Double(right + 1), Double(bottom + 1)]
    }

    private func peakCenter(_ scores: ArraySlice<Int>) throws -> Double {
        guard let peak = scores.max(), peak > 30 else {
            throw NotchWindowGlowFailure(
                message: "motion capture must contain a solid colored edge; peak \(scores.max() ?? -1), " +
                    "axis \(scores.startIndex)..<\(scores.endIndex)"
            )
        }
        let indices = scores.indices.filter { scores[$0] >= peak - 3 }
        return Double(indices.reduce(0, +)) / Double(indices.count) + 0.5
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

@MainActor
private struct NotchWindowMotionProbe {
    let controller: NotchPanelController
    let scale: CGFloat
    let reduceMotion: Bool
    let advanceClock: () -> Void

    func show(_ visibility: NotchVisibility) {
        controller.update(
            interactionState: NotchInteractionState(
                visibility: visibility, presentationState: MewsPresentationState(event: nil)
            ),
            accessibilityPreferences: NotchAccessibilityPreferences(
                reduceMotion: reduceMotion, reduceTransparency: false, increaseContrast: false
            )
        )
    }

    func sample(until height: Double, expectsMotion: Bool, crossesHeight: Bool = false) throws {
        var intermediateFrames = 0
        var maximumError = 0.0
        for _ in 0..<60 {
            advanceClock()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            let edges = try captureEdges()
            for (backing, glow) in zip(edges.backing, edges.glow) {
                maximumError = max(maximumError, abs(backing - glow))
            }
            let edgeTolerance = NotchShellShape.outlineWidth(increaseContrast: false) * scale
            guard maximumError <= edgeTolerance else {
                throw NotchWindowGlowFailure(
                    message: "motion \(scale)x: backing \(edges.backing), glow \(edges.glow), " +
                        "error \(maximumError)px; " +
                        ProcessInfo.processInfo.operatingSystemVersionString
                )
            }
            let bottom = edges.backing[2] / scale
            if bottom > 34 && bottom < 218 {
                intermediateFrames += 1
                guard !controller.revealsPhysicalContent else {
                    throw NotchWindowGlowFailure(
                        message: "content must remain hidden while the backing is moving"
                    )
                }
            }
            guard !reduceMotion || intermediateFrames == 0 else {
                throw NotchWindowGlowFailure(message: "Reduce Motion must not animate shell geometry")
            }
            let glowBottom = edges.glow[2] / scale
            let pointTolerance =
                NotchShellShape.outlineWidth(increaseContrast: false) / 2
            let reached = crossesHeight ? min(bottom, glowBottom) >= height :
                abs(bottom - height) <= pointTolerance &&
                    abs(glowBottom - height) <= pointTolerance
            if reached {
                guard !expectsMotion || intermediateFrames > 0 else {
                    throw NotchWindowGlowFailure(message: "spatial transition must render intermediate geometry")
                }
                print("Notch motion \(scale)x -> \(height)pt: \(intermediateFrames) intermediate frames, " +
                    "maximum edge error \(maximumError)px")
                return
            }
        }
        throw NotchWindowGlowFailure(message: "native shell motion did not reach \(height)pt")
    }

    private func captureEdges() throws -> (backing: [Double], glow: [Double]) {
        guard let glowPanel = controller.panel.childWindows?.first,
              let visualView = glowPanel.contentView else {
            throw NotchWindowGlowFailure(message: "motion requires the passive visual window")
        }
        let visual = try NotchWindowRaster.captureLayer(
            visualView,
            size: glowPanel.frame.size,
            scale: scale
        )
        var backingEdges = try visual.motionEdges(glow: false)
        backingEdges[0] -= NotchGlowPanel.margin * scale
        backingEdges[1] -= NotchGlowPanel.margin * scale
        return try (backingEdges, visual.motionEdges(glow: true))
    }
}

private struct NotchRasterPixel {
    let red: Int
    let green: Int
    let blue: Int
}

struct NotchWindowGlowFailure: Error {
    let message: String
}
