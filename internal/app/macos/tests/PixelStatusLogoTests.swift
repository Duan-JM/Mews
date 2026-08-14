import Foundation

extension MewsAppModelTests {
    static func testPixelStatusLogoPlans() throws {
        let states = try pixelPresentationStates()
        let plans = states.map {
            PixelStatusLogo.animationPlan(for: $0, reduceMotion: false)
        }

        try pixelExpect(plans[0].frames.count == 1, "idle should have one static frame")
        try pixelExpect(plans[0].frameInterval == nil, "idle should not keep a timer")
        try pixelExpect(!plans[0].repeats, "idle should not repeat")

        try pixelExpect(plans[1].frames.count == 2, "running should have exactly two frames")
        try pixelExpect(plans[1].repeats, "running should repeat")
        try pixelExpect(
            (plans[1].frameInterval ?? 0) >= 0.5,
            "running should animate at no more than two frames per second"
        )

        try pixelExpect(plans[2].frames.count >= 2, "attention should have a visible signal")
        try pixelExpect(plans[2].repeats, "attention should repeat")
        try pixelExpect(
            (plans[2].frameInterval ?? 0) >= 0.5,
            "attention should animate at no more than two frames per second"
        )

        try pixelExpect(plans[3].frames.count == 3, "done should have exactly three frames")
        try pixelExpect(!plans[3].repeats, "done should play once")
        try pixelExpect(plans[3].totalDuration <= 1, "done should settle within one second")

        try pixelExpect(plans[4].frames.count == 3, "failed should have exactly three frames")
        try pixelExpect(!plans[4].repeats, "failed should play once")
        try pixelExpect(plans[4].totalDuration <= 1, "failed should settle within one second")

        try testPixelFrameIntegrity(plans: plans, states: states)
    }

    private static func testPixelFrameIntegrity(
        plans: [PixelStatusAnimationPlan],
        states: [MewsPresentationState]
    ) throws {
        let stableFrames = Set(plans.map(\.stableFrame))
        try pixelExpect(stableFrames.count == states.count, "all five stable poses should be distinct")
        let renderedImage = PixelStatusLogoRenderer.image(for: plans[0].stableFrame)
        try pixelExpect(renderedImage.isTemplate, "the menu bar logo should render as a template image")
        try pixelExpect(
            renderedImage.size == PixelStatusLogoRenderer.imageSize,
            "the rendered logo should preserve the 16 by 16 logical size"
        )

        for plan in plans {
            for frame in plan.frames {
                try pixelExpect(!frame.pixels.isEmpty, "every frame should contain visible pixels")
                for pixel in frame.pixels {
                    try pixelExpect(
                        (0..<PixelFrame.gridSize).contains(pixel.column) &&
                            (0..<PixelFrame.gridSize).contains(pixel.row),
                        "every pixel should stay inside the 16 by 16 grid"
                    )
                }
            }
        }

        for state in states {
            let plan = PixelStatusLogo.animationPlan(for: state, reduceMotion: true)
            try pixelExpect(plan.frames.count == 1, "Reduce Motion should produce one frame")
            try pixelExpect(plan.frameInterval == nil, "Reduce Motion should not keep a timer")
            try pixelExpect(!plan.repeats, "Reduce Motion should not repeat")
        }
    }

    private static func pixelPresentationStates() throws -> [MewsPresentationState] {
        return [
            MewsPresentationState(event: nil),
            MewsPresentationState(event: try pixelDecodeEvent(status: "running")),
            MewsPresentationState(event: try pixelDecodeEvent(status: "needs_input")),
            MewsPresentationState(event: try pixelDecodeEvent(status: "done")),
            MewsPresentationState(event: try pixelDecodeEvent(status: "failed"))
        ]
    }

    private static func pixelDecodeEvent(status: String) throws -> MewsEvent {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "source": "copilot",
                "status": status,
                "agent_scope": "main",
                "timestamp": "2026-07-20T12:00:00Z"
            ]
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MewsEvent.self, from: data)
    }

    private static func pixelExpect(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw PixelStatusLogoTestFailure(message: message)
        }
    }
}

private struct PixelStatusLogoTestFailure: Error {
    let message: String
}
