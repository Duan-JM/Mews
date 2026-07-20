import AppKit
import Foundation

struct PixelPoint: Hashable {
    let column: Int
    let row: Int
}

struct PixelFrame: Hashable {
    static let gridSize = 16

    let pixels: [PixelPoint]

    init(rows: [String]) {
        precondition(rows.count == Self.gridSize)

        var pixels: [PixelPoint] = []
        for (rowIndex, row) in rows.enumerated() {
            precondition(row.count == Self.gridSize)
            for (columnIndex, character) in row.enumerated() {
                precondition(character == "." || character == "#")
                if character == "#" {
                    pixels.append(PixelPoint(column: columnIndex, row: rowIndex))
                }
            }
        }
        precondition(!pixels.isEmpty)
        self.pixels = pixels
    }
}

struct PixelStatusAnimationPlan: Equatable {
    let frames: [PixelFrame]
    let frameInterval: TimeInterval?
    let repeats: Bool
    let stableFrame: PixelFrame

    var totalDuration: TimeInterval {
        guard let frameInterval else {
            return 0
        }
        return frameInterval * Double(max(frames.count - 1, 0))
    }
}

enum PixelStatusLogo {
    static func animationPlan(
        for state: MewsPresentationState,
        reduceMotion: Bool
    ) -> PixelStatusAnimationPlan {
        let plan = animationPlan(for: state.status)
        guard reduceMotion else {
            return plan
        }
        return PixelStatusAnimationPlan(
            frames: [plan.stableFrame],
            frameInterval: nil,
            repeats: false,
            stableFrame: plan.stableFrame
        )
    }

    private static func animationPlan(
        for status: MewsPresentationStatus
    ) -> PixelStatusAnimationPlan {
        switch status {
        case .idle:
            return staticPlan(frame: PixelStatusFrames.sleeping)
        case .running:
            return repeatingPlan(
                frames: [PixelStatusFrames.workingLeft, PixelStatusFrames.workingRight],
                interval: 0.5
            )
        case .needsInput:
            return repeatingPlan(
                frames: [PixelStatusFrames.attentionQuiet, PixelStatusFrames.attentionSignal],
                interval: 0.5
            )
        case .done:
            return oneShotPlan(
                frames: [
                    PixelStatusFrames.successLift,
                    PixelStatusFrames.successSpark,
                    PixelStatusFrames.successStable
                ],
                interval: 0.25
            )
        case .failed:
            return oneShotPlan(
                frames: [
                    PixelStatusFrames.failureDrop,
                    PixelStatusFrames.failureShake,
                    PixelStatusFrames.failureStable
                ],
                interval: 0.25
            )
        }
    }

    private static func staticPlan(frame: PixelFrame) -> PixelStatusAnimationPlan {
        return PixelStatusAnimationPlan(
            frames: [frame],
            frameInterval: nil,
            repeats: false,
            stableFrame: frame
        )
    }

    private static func repeatingPlan(
        frames: [PixelFrame],
        interval: TimeInterval
    ) -> PixelStatusAnimationPlan {
        guard let stableFrame = frames.first else {
            preconditionFailure("A repeating pixel animation needs a frame")
        }
        return PixelStatusAnimationPlan(
            frames: frames,
            frameInterval: interval,
            repeats: true,
            stableFrame: stableFrame
        )
    }

    private static func oneShotPlan(
        frames: [PixelFrame],
        interval: TimeInterval
    ) -> PixelStatusAnimationPlan {
        guard let stableFrame = frames.last else {
            preconditionFailure("A one-shot pixel animation needs a frame")
        }
        return PixelStatusAnimationPlan(
            frames: frames,
            frameInterval: interval,
            repeats: false,
            stableFrame: stableFrame
        )
    }

}

private enum PixelStatusFrames {
    static func frame(_ rows: String) -> PixelFrame {
        return PixelFrame(rows: rows.split(separator: "\n").map(String.init))
    }

    static let sleeping = frame(
        """
        ................
        ................
        ..##........##..
        .#..#......#..#.
        .#...######...#.
        .#............#.
        .#..##....##..#.
        .#............#.
        .#....####....#.
        ..#..........#..
        ...##########...
        .....######.....
        ...##########...
        ..##........##..
        ...##########...
        ................
        """
    )

    static let workingLeft = frame(
        """
        ................
        ..##........##..
        .#..#......#..#.
        .#...######...#.
        .#............#.
        .#...#....#...#.
        .#.....##.....#.
        ..#..........#..
        ...##########...
        .....#....#.....
        ...###....##....
        ..############..
        ..#..........#..
        ..############..
        ....##....##....
        ................
        """
    )

    static let workingRight = frame(
        """
        ................
        ..##........##..
        .#..#......#..#.
        .#...######...#.
        .#............#.
        .#...#....#...#.
        .#.....##.....#.
        ..#..........#..
        ...##########...
        .....#....#.....
        ....##....###...
        ..############..
        ..#..........#..
        ..############..
        ...##......##...
        ................
        """
    )

    static let attentionQuiet = frame(
        """
        .............#..
        ..##......##.#..
        .#..#....#..##..
        .#...####...##..
        .#..........##..
        .#..#....#..##..
        .#....##....#...
        ..#........#....
        ...########.....
        ....##..##......
        ...##....##.....
        ..##......##....
        ..#........#....
        ..##########....
        ...##....##.....
        ................
        """
    )

    static let attentionSignal = frame(
        """
        ............###.
        ..##......##.#..
        .#..#....#..##..
        .#...####...#...
        .#..........#.#.
        .#..#....#..#.#.
        .#....##....#...
        ..#........#..#.
        ...########...#.
        ....##..##......
        ...##....##.....
        ..##......##....
        ..#........#....
        ..##########....
        ...##....##.....
        ................
        """
    )

    static let successLift = frame(
        """
        .............#..
        ..##........##..
        .#..#......#..#.
        .#...######...#.
        .#............#.
        .#...#....#...#.
        .#.....##.....#.
        ..#..........#..
        ...##########...
        ....##....##....
        ...##......##...
        ..##........##..
        ..#..........#..
        ...##......##...
        ....########....
        ................
        """
    )

    static let successSpark = frame(
        """
        .#...........#..
        ###.........###.
        .###........##..
        .#..#......#..#.
        .#...######...#.
        .#............#.
        .#...#....#...#.
        .#.....##.....#.
        ..#..........#..
        ...##########...
        ....##....##....
        ...##......##...
        ..##........##..
        ...##......##...
        ....########....
        ................
        """
    )

    static let successStable = frame(
        """
        .#...........#..
        ###.##....##.###
        .#.#..#..#..#.#.
        ..#...####...#..
        ..#..........#..
        ..#..#....#..#..
        ..#...####...#..
        ...#........#...
        ....########....
        .....##..##.....
        ....##....##....
        ...##......##...
        ...#........#...
        ...##########...
        ....##....##....
        ................
        """
    )

    static let failureDrop = frame(
        """
        ................
        ..##........##..
        .#..#......#..#.
        .#...######...#.
        .#............#.
        .#..#.#..#.#..#.
        .#...#....#...#.
        ..#..........#..
        ...##########...
        ....##....##....
        ...##......##...
        ..##........##..
        ..#..........#..
        ..############..
        ...##......##...
        ................
        """
    )

    static let failureShake = frame(
        """
        ................
        .##........##...
        #..#......#..#..
        #...######...#..
        #............#..
        #..#.#..#.#..#..
        #...#....#...#..
        .#..........#...
        ..##########....
        ...##....##.....
        ..##......##....
        .##........##...
        .#..........#...
        .############...
        ..##......##....
        ................
        """
    )

    static let failureStable = frame(
        """
        ................
        ...##......##...
        ..#..#....#..#..
        ..#...####...#..
        ..#..........#..
        ..#..#.#..#.#...
        ..#...#....#....
        ...#........#...
        ....########....
        .....##..##.....
        ....##....##....
        ...##......##...
        ...#........#...
        ...##########...
        ..##........##..
        ................
        """
    )
}

enum PixelStatusLogoRenderer {
    static let imageSize = NSSize(width: 16, height: 16)

    static func image(for frame: PixelFrame) -> NSImage {
        let image = NSImage(size: imageSize, flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }

            NSGraphicsContext.current?.shouldAntialias = false
            NSGraphicsContext.current?.imageInterpolation = .none
            NSColor.black.setFill()

            let unit = min(rect.width, rect.height) / CGFloat(PixelFrame.gridSize)
            let originX = rect.midX - (unit * CGFloat(PixelFrame.gridSize) / 2)
            let originY = rect.midY - (unit * CGFloat(PixelFrame.gridSize) / 2)
            for pixel in frame.pixels {
                NSRect(
                    x: originX + CGFloat(pixel.column) * unit,
                    y: originY + CGFloat(PixelFrame.gridSize - pixel.row - 1) * unit,
                    width: unit,
                    height: unit
                ).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
