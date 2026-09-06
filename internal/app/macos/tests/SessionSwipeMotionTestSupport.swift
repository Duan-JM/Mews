import AppKit
import SwiftUI

@MainActor
final class SwipeMotionFixture {
    let row: SessionPresentationRow
    let request: SessionDismissalRequest
    let model: SessionListPresentationModel
    let persistence = SwipeMotionPersistence()
    let host: NSView
    let window: NSWindow

    init(
        reduceMotion: Bool = false,
        colorScheme: ColorScheme = .light,
        reduceTransparency: Bool = true,
        increaseContrast: Bool = false
    ) throws {
        _ = NSApplication.shared
        row = try MewsAppModelTests.listRow(id: "motion-fixture", evidenceID: "motion-1")
        guard let request = row.dismissalRequest else {
            throw SwipeMotionTestError.expectation("the native fixture must be dismissible")
        }
        self.request = request
        let persistence = persistence
        model = SessionListPresentationModel { request, completion in
            persistence.requests.append(request)
            persistence.completion = completion
        }
        model.updateAccessibility(reduceMotion: reduceMotion)
        model.update(canonicalRows: [row], revision: 1)
        let content = Self.content(
            model: model, reduceMotion: reduceMotion, colorScheme: colorScheme,
            reduceTransparency: reduceTransparency, increaseContrast: increaseContrast
        )
        host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        window = NSWindow(
            contentRect: CGRect(x: 40, y: 40, width: 356, height: 180),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    func close() {
        model.cancelForLifecycle()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    func beginDrag(distance: CGFloat) {
        model.inputRouter.begin(SessionSwipeInputTarget(request: request, rowWidth: 320))
        model.inputRouter.change(translationX: -distance, velocityX: -240)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func sampleActionBounds(duration: TimeInterval = 0.4) throws -> [CGRect] {
        return try sampleActionFrames(duration: duration).map { $0.button }
    }

    func sampleActionFrames(duration: TimeInterval = 0.4) throws -> [(button: CGRect, label: CGRect)] {
        let deadline = Date().addingTimeInterval(duration)
        var frames: [(button: CGRect, label: CGRect)] = []
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            frames.append(try captureActionFrame())
        } while Date() < deadline
        return frames
    }

    func captureActionBounds() throws -> CGRect {
        return try captureActionFrame().button
    }

    func captureActionFrame() throws -> (button: CGRect, label: CGRect) {
        guard let bitmap = try captureDocument() else {
            return (.zero, .zero)
        }
        let button = try Self.redBounds(bitmap)
        // The inset excludes the border; small white glyphs are antialiased in a 1x capture.
        let label = try Self.pixelBounds(bitmap, within: button.insetBy(dx: 2, dy: 2)) { pixel in
            pixel[0] > 220 && pixel[1] > 150 && pixel[2] > 150 && pixel[3] > 200
        }
        return (button, label)
    }

    func captureTrackWidth() throws -> CGFloat {
        guard let bitmap = try captureDocument(), let pixels = bitmap.bitmapData else {
            throw SwipeMotionTestError.expectation("the track must have a rendered document")
        }
        var width = 0
        for column in 0..<bitmap.pixelsWide {
            let pixel = pixels + 2 * bitmap.bytesPerRow + column * 4
            if pixel[3] > 8 {
                width += 1
            }
        }
        return CGFloat(width)
    }

    func captureTrackOpacity(column: Int = 318, row: Int = 2) throws -> Double {
        guard let bitmap = try captureDocument(), let pixels = bitmap.bitmapData,
              column >= 0, row >= 0, bitmap.pixelsWide > column, bitmap.pixelsHigh > row else {
            throw SwipeMotionTestError.expectation("the track must contain a material sample")
        }
        let pixel = pixels + row * bitmap.bytesPerRow + column * 4
        return Double(pixel[3]) / 255
    }

    func captureControlHeight(column: Int) throws -> CGFloat {
        let rowHeight = Int(SessionRowLayout.rowHeight)
        guard let bitmap = try captureDocument(), let pixels = bitmap.bitmapData,
              column >= 0, bitmap.pixelsWide > column, bitmap.pixelsHigh >= rowHeight else {
            throw SwipeMotionTestError.expectation("the resting control must have a complete row")
        }
        let paintedRows = (0..<(rowHeight - 1)).filter { row in
            return pixels[row * bitmap.bytesPerRow + column * 4 + 3] > 8
        }
        guard let first = paintedRows.first, let last = paintedRows.last else {
            throw SwipeMotionTestError.expectation("the resting control must contain rendered pixels")
        }
        return CGFloat(last - first + 1)
    }

    private func captureDocument() throws -> NSBitmapImageRep? {
        host.layoutSubtreeIfNeeded()
        guard let document = Self.sessionDocument(in: host) else {
            guard model.snapshot.rows.isEmpty else {
                throw SwipeMotionTestError.expectation("nonempty sessions must have a native document")
            }
            return nil
        }
        let width = Int(ceil(document.bounds.width))
        let height = Int(ceil(document.bounds.height))
        guard width > 0, height > 0 else {
            return nil
        }
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            throw SwipeMotionTestError.expectation("could not allocate native render capture")
        }
        bitmap.size = document.bounds.size
        document.cacheDisplay(in: document.bounds, to: bitmap)
        return bitmap
    }

    private static func sessionDocument(in view: NSView) -> NSView? {
        if let scrollView = view as? SessionListScrollView {
            return scrollView.hostedDocumentView
        }
        return view.subviews.lazy.compactMap { sessionDocument(in: $0) }.first
    }

    private static func redBounds(_ bitmap: NSBitmapImageRep) throws -> CGRect {
        let region = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        return try pixelBounds(bitmap, within: region) { pixel in
            let red = Int(pixel[0])
            return red > 140 && red > Int(pixel[1]) + 30 && red > Int(pixel[2]) + 20 && pixel[3] > 200
        }
    }

    private static func pixelBounds(
        _ bitmap: NSBitmapImageRep,
        within region: CGRect,
        matching matches: (UnsafeMutablePointer<UInt8>) -> Bool
    ) throws -> CGRect {
        guard let pixels = bitmap.bitmapData else {
            throw SwipeMotionTestError.expectation("native capture must contain pixels")
        }
        guard !region.isEmpty else {
            return .zero
        }
        var minX = bitmap.pixelsWide
        var minY = bitmap.pixelsHigh
        var maxX = -1
        var maxY = -1
        for row in max(0, Int(region.minY))..<min(bitmap.pixelsHigh, Int(region.maxY)) {
            for column in max(0, Int(region.minX))..<min(bitmap.pixelsWide, Int(region.maxX)) {
                let pixel = pixels + row * bitmap.bytesPerRow + column * 4
                if matches(pixel) {
                    minX = min(minX, column)
                    minY = min(minY, row)
                    maxX = max(maxX, column)
                    maxY = max(maxY, row)
                }
            }
        }
        return maxX >= minX
            ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            : .zero
    }

    private static func content(
        model: SessionListPresentationModel,
        reduceMotion: Bool,
        colorScheme: ColorScheme,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> some View {
        let snapshot = NotchShellSnapshot(
            visibility: .expanded, placementMode: .topCenter,
            panelSize: CGSize(width: 356, height: 180), anchorSize: .zero,
            presentationState: MewsPresentationState(event: nil), content: .empty,
            transitionStyle: reduceMotion ? .opacityOnly : .spatial,
            reduceTransparency: reduceTransparency, increaseContrast: increaseContrast
        )
        let surface = NotchSurfacePalette.resolved(
            placementMode: .topCenter, colorScheme: colorScheme, increaseContrast: increaseContrast
        )
        return NotchExpandedContentView(
            snapshot: snapshot, sessionListModel: model, surface: surface,
            onReturnToCLI: { _, _ in }, onCopyCommand: { _ in }
        )
        .frame(width: 356, height: 180)
        .modifier(NotchShellSurfaceModifier(
            snapshot: snapshot, geometry: .resolved(snapshot: snapshot), surface: surface
        ))
        .environment(\.colorScheme, colorScheme)
    }
}

@MainActor
final class SwipeMotionPersistence {
    var requests: [SessionDismissalRequest] = []
    var completion: ((Result<SessionDismissalResponse, Error>) -> Void)?
}

enum SwipeMotionTestError: Error {
    case writeFailed
    case expectation(String)
}
