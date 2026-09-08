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
            for height: CGFloat in [24, 32, 44] {
                for status in [SessionStatus.running, .needsInput, .done] {
                    try assertGlowPixels(
                        snapshot: boundedGlowSnapshot(height: height, status: status),
                        scale: scale
                    )
                }
                try assertGlowPixels(
                    snapshot: boundedGlowSnapshot(height: height, visibility: .peek),
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
        print("Notch glow bounds: 24 collapsed and 4 expanded native renders passed at 1x/2x")
    }

    private static func boundedGlowSnapshot(
        height: CGFloat = 32,
        visibility: NotchVisibility = .closed,
        mode: OverlayPlacementMode = .notch,
        status: SessionStatus = .running
    ) -> NotchShellSnapshot {
        return NotchShellSnapshot(
            visibility: visibility,
            placementMode: mode,
            panelSize: CGSize(width: 420, height: 220),
            anchorSize: CGSize(width: 180, height: height),
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
        let top = 40 * scale
        let bottom = (40 + snapshot.anchorSize.height) * scale
        if snapshot.visibility == .expanded {
            guard bounds.maxY > bottom + 100 * scale else {
                throw GlowBoundsFailure("expanded glow must retain its full-height edge")
            }
        } else {
            guard bounds.minY >= top, bounds.maxY <= bottom else {
                throw GlowBoundsFailure(
                    "\(snapshot.visibility) glow pixels \(bounds.minY)..<\(bounds.maxY) " +
                    "escape menu band \(top)..<\(bottom) at \(scale)x"
                )
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
            NotchShellView(model: model, sessionListModel: sessions)
                .padding(40)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
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

private struct GlowBoundsFailure: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
