import AppKit
import SwiftUI

extension MewsAppModelTests {
    static func testNotchGlowBounds() throws {
        for height: CGFloat in [24, 32, 37.5, 44] {
            for visibility in [NotchVisibility.closed, .peek] {
                let snapshot = boundedGlowSnapshot(height: height, visibility: visibility)
                let layout = NotchShellLayout.resolved(snapshot: snapshot)
                guard layout.height == height, layout.contentHeight == 0 else {
                    throw GlowBoundsFailure("collapsed height \(layout.height) exceeds anchor \(height)")
                }
            }
        }
        for scale: CGFloat in [1, 2] {
            for size in [
                CGSize(width: 180, height: 24), CGSize(width: 179, height: 32),
                CGSize(width: 220, height: 44), CGSize(width: 179, height: 37.5)
            ] {
                for status in [SessionStatus.running, .needsInput, .done] {
                    try assertGlowPixels(
                        snapshot: boundedGlowSnapshot(height: size.height, status: status, width: size.width),
                        scale: scale
                    )
                }
                try assertGlowPixels(
                    snapshot: boundedGlowSnapshot(height: size.height, visibility: .peek, width: size.width),
                    scale: scale
                )
            }
            for mode in [OverlayPlacementMode.notch, .topCenter] {
                try assertGlowPixels(
                    snapshot: boundedGlowSnapshot(visibility: .expanded, mode: mode),
                    scale: scale
                )
            }
        }
        print("Notch glow: 32 collapsed and 4 expanded renders passed; contact/normal-width tolerance 0.75px at 1x/2x")
    }

    private static func boundedGlowSnapshot(
        height: CGFloat = 32,
        visibility: NotchVisibility = .closed,
        mode: OverlayPlacementMode = .notch,
        status: SessionStatus = .running,
        width: CGFloat = 180
    ) -> NotchShellSnapshot {
        return NotchShellSnapshot(
            visibility: visibility,
            placementMode: mode,
            panelSize: CGSize(width: 420, height: 220),
            anchorSize: CGSize(width: width, height: height),
            presentationState: MewsPresentationState(event: nil),
            content: NotchPanelContent(
                presentation: SessionPresentation(rows: [], aggregateStatuses: [status], health: nil),
                events: [],
                currentEvent: nil
            ),
            transitionStyle: .opacityOnly,
            reduceTransparency: false,
            increaseContrast: status == .needsInput
        )
    }

    private static func assertGlowPixels(
        snapshot: NotchShellSnapshot,
        scale: CGFloat
    ) throws {
        let bitmap = try renderGlow(snapshot: snapshot, scale: scale)
        let bounds = try coloredPixelBounds(bitmap)
        let bottom = (40 + snapshot.anchorSize.height) * scale
        if snapshot.visibility == .expanded {
            guard bounds.maxY > bottom + 100 * scale else {
                throw GlowBoundsFailure("expanded glow must retain its full-height edge")
            }
        } else {
            try GlowContourRaster(bitmap: bitmap, snapshot: snapshot, scale: scale).assertOutline()
            let lineWidth: CGFloat = snapshot.increaseContrast ? 2 : 1.5
            guard bounds.maxY > bottom + lineWidth * scale else {
                throw GlowBoundsFailure("soft glow must extend below the solid bottom edge")
            }
            let notchLeft = (40 + (snapshot.panelSize.width - snapshot.anchorSize.width) / 2) * scale
            let notchRight = notchLeft + snapshot.anchorSize.width * scale
            guard bounds.minX < notchLeft, bounds.maxX > notchRight else {
                throw GlowBoundsFailure("horizontal glow must remain visible beside the hardware")
            }
        }
    }

    private static func renderGlow(
        snapshot: NotchShellSnapshot,
        scale: CGFloat
    ) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let model = NotchShellViewModel(snapshot: snapshot)
        let sessions = SessionListPresentationModel { _, _ in }
        let host = NSHostingView(rootView:
            ZStack(alignment: .top) {
                NotchShellView(model: model, sessionListModel: sessions)
                if snapshot.placementMode == .notch && snapshot.visibility != .expanded {
                    NotchShellShape.PhysicalNotchGlowShape(cornerRadius: 8)
                        .fill(Color.black)
                        .frame(width: snapshot.anchorSize.width, height: snapshot.anchorSize.height)
                }
            }
            .padding(40)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
            .environment(\.displayScale, scale)
        )
        let size = CGSize(width: snapshot.panelSize.width + 80, height: snapshot.panelSize.height + 80)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            throw GlowBoundsFailure("could not allocate native glow capture")
        }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private static func coloredPixelBounds(_ bitmap: NSBitmapImageRep) throws -> CGRect {
        guard let pixels = bitmap.bitmapData else {
            throw GlowBoundsFailure("native glow capture has no pixels")
        }
        var minX = bitmap.pixelsWide
        var minY = bitmap.pixelsHigh
        var maxX = -1
        var maxY = -1
        for row in 0..<bitmap.pixelsHigh {
            for column in 0..<bitmap.pixelsWide {
                let pixel = pixels + row * bitmap.bytesPerRow + column * 4
                let red = Int(pixel[0])
                let green = Int(pixel[1])
                let blue = Int(pixel[2])
                if max(red, green) > blue + 2, abs(red - green) > 2 {
                    minX = min(minX, column)
                    minY = min(minY, row)
                    maxX = max(maxX, column)
                    maxY = max(maxY, row)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else {
            throw GlowBoundsFailure("native glow capture must contain colored pixels")
        }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

@MainActor
private struct GlowContourRaster {
    let bitmap: NSBitmapImageRep
    let snapshot: NotchShellSnapshot
    let scale: CGFloat

    func assertOutline() throws {
        let expectedWidth = (snapshot.increaseContrast ? 2.0 : 1.5) * scale
        let threshold = snapshot.increaseContrast ? 100.0 : 85.0
        var failures: [String] = []
        var widths: [Double] = []
        for sample in contourSamples() {
            let distances = stride(from: -2.0, through: expectedWidth + 10, by: 0.125).filter { distance in
                score(at: CGPoint(
                    x: sample.point.x * scale + sample.normal.dx * distance,
                    y: sample.point.y * scale + sample.normal.dy * distance
                )) >= threshold
            }
            guard let first = distances.first, let last = distances.last else {
                failures.append("\(sample.name): no solid edge outside hardware")
                continue
            }
            let width = last - first + 0.125
            widths.append(width)
            if abs(first) > 0.75 || abs(width - expectedWidth) > 0.75 {
                failures.append("\(sample.name): gap=\(first)px width=\(width)px, expected 0/\(expectedWidth)px")
            }
        }
        if let minimum = widths.min(), let maximum = widths.max(), maximum - minimum > 0.75 {
            failures.append("straight/corner widths differ by \(maximum - minimum)px")
        }
        guard failures.isEmpty else {
            throw GlowBoundsFailure(
                "outline \(snapshot.anchorSize) at \(scale)x: " + failures.joined(separator: "; ")
            )
        }
    }

    private func contourSamples() -> [GlowContourSample] {
        let width = NotchShellLayout.resolved(snapshot: snapshot).width
        let left = 40 + (snapshot.panelSize.width - width) / 2
        let right = left + width
        let bottom = 40 + snapshot.anchorSize.height
        let middle = 40 + snapshot.anchorSize.height / 2
        let radius: CGFloat = 8
        var samples = [
            GlowContourSample(name: "left", point: CGPoint(x: left, y: middle), normal: CGVector(dx: -1, dy: 0)),
            GlowContourSample(name: "right", point: CGPoint(x: right, y: middle), normal: CGVector(dx: 1, dy: 0)),
            GlowContourSample(
                name: "bottom", point: CGPoint(x: (left + right) / 2, y: bottom), normal: CGVector(dx: 0, dy: 1)
            )
        ]
        for progress: CGFloat in [0.15, 0.5, 0.85] {
            let offsetX = radius * pow(1 - progress, 2)
            let offsetY = radius * pow(progress, 2)
            let length = hypot(progress, 1 - progress)
            for side: CGFloat in [-1, 1] {
                samples.append(GlowContourSample(
                    name: "corner \(side)/\(progress)",
                    point: CGPoint(x: side < 0 ? left + offsetX : right - offsetX, y: bottom - offsetY),
                    normal: CGVector(dx: side * progress / length, dy: (1 - progress) / length)
                ))
            }
        }
        return samples
    }

    private func score(at point: CGPoint) -> Double {
        let pixelX = point.x - 0.5
        let pixelY = point.y - 0.5
        let column = Int(floor(pixelX))
        let row = Int(floor(pixelY))
        let fractionX = pixelX - CGFloat(column)
        let fractionY = pixelY - CGFloat(row)
        let top = pixelScore(x: column, y: row) * (1 - fractionX) +
            pixelScore(x: column + 1, y: row) * fractionX
        let bottom = pixelScore(x: column, y: row + 1) * (1 - fractionX) +
            pixelScore(x: column + 1, y: row + 1) * fractionX
        return top * (1 - fractionY) + bottom * fractionY
    }

    private func pixelScore(x column: Int, y row: Int) -> Double {
        precondition(column >= 0 && row >= 0 && column < bitmap.pixelsWide && row < bitmap.pixelsHigh)
        guard let pixels = bitmap.bitmapData else {
            preconditionFailure("native contour capture has no pixels")
        }
        let pixel = pixels + row * bitmap.bytesPerRow + column * 4
        return Double(abs(Int(pixel[0]) - Int(pixel[1])))
    }
}

private struct GlowContourSample {
    let name: String
    let point: CGPoint
    let normal: CGVector
}

private struct GlowBoundsFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
