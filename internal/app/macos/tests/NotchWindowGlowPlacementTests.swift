import AppKit

extension MewsAppModelTests {
    static func checkWindowGlow(
        snapshot: NotchShellSnapshot, scale: CGFloat, failures: inout [String]
    ) throws {
        let screenState = GlowScreenState(
            screens: [windowGlowScreen(mode: snapshot.placementMode)]
        )
        let controller = NotchPanelController(screenProvider: { screenState.screens })
        defer { controller.hide() }
        showWindowGlow(controller, snapshot: snapshot)
        guard let placement = controller.placement else {
            throw NotchWindowGlowFailure(message: "missing real panel content")
        }
        let glowPanel = controller.panel.childWindows?.first
        let rasterPanel = snapshot.placementMode == .notch ? glowPanel : controller.panel
        guard let rasterPanel, let host = rasterPanel.contentView else {
            throw NotchWindowGlowFailure(message: "missing raster panel content")
        }
        let shell = controller.panel.frame
        let window = rasterPanel.frame
        let raster = try snapshot.placementMode == .notch
            ? NotchWindowRaster.captureLayer(host, size: window.size, scale: scale)
            : NotchWindowRaster.capture(host, size: window.size, scale: scale)
        if glowPanel?.ignoresMouseEvents == false || shell.size != placement.frame.size {
            failures.append("native \(scale)x: halo must not enlarge the input window")
        }
        checkGlowPixels(
            probe: GlowPixelProbe(
                snapshot: snapshot, controller: controller, raster: raster,
                window: window, shell: shell, scale: scale
            ),
            failures: &failures
        )
        if !controller.containsVisibleShell(CGPoint(x: shell.midX, y: shell.minY + 30)) {
            failures.append("native \(scale)x: actual shell must remain interactive")
        }
        checkGlowLifecycle(
            probe: GlowLifecycleProbe(
                snapshot: snapshot, controller: controller, glowPanel: glowPanel,
                screenState: screenState, scale: scale
            ),
            failures: &failures
        )
    }

    private static func checkGlowPixels(
        probe: GlowPixelProbe,
        failures: inout [String]
    ) {
        let points = probe.snapshot.placementMode == .notch
            ? [
                CGPoint(x: probe.shell.minX - 6, y: probe.shell.midY),
                CGPoint(x: probe.shell.maxX + 6, y: probe.shell.midY),
                CGPoint(x: probe.shell.midX, y: probe.shell.minY - 6)
            ]
            : [
                CGPoint(x: probe.shell.minX + 1, y: probe.shell.midY),
                CGPoint(x: probe.shell.maxX - 1, y: probe.shell.midY),
                CGPoint(x: probe.shell.midX, y: probe.shell.minY + 1)
            ]
        let glowVisible = NotchGlowPresentation.resolved(
            snapshot: probe.snapshot
        ).isVisible
        for point in points {
            let localPoint = CGPoint(
                x: point.x - probe.window.minX, y: probe.window.maxY - point.y
            )
            let colorScore = probe.raster.colorScore(at: localPoint)
            if probe.snapshot.placementMode == .notch &&
                glowVisible && colorScore < 3 {
                failures.append("native \(probe.scale)x: missing notch halo at \(point)")
            }
            if probe.snapshot.placementMode == .notch &&
                !glowVisible && colorScore > 2 {
                failures.append("native \(probe.scale)x: idle shell leaked colored halo at \(point)")
            }
            if probe.snapshot.placementMode == .topCenter && colorScore > 2 {
                failures.append("native \(probe.scale)x: top-center leaked colored halo at \(point)")
            }
            if probe.snapshot.placementMode == .notch &&
                probe.controller.containsVisibleShell(point) {
                failures.append("native \(probe.scale)x: transparent halo intercepts clicks")
            }
        }
        let shellCenter = CGPoint(
            x: probe.shell.midX - probe.window.minX,
            y: probe.window.maxY - probe.shell.midY
        )
        if probe.snapshot.placementMode == .notch &&
            probe.raster.alpha(at: shellCenter) < 128 {
            failures.append("native \(probe.scale)x: expanded idle shell lost its black backing")
        }
    }

    private static func checkGlowLifecycle(
        probe: GlowLifecycleProbe,
        failures: inout [String]
    ) {
        probe.controller.hide()
        if probe.glowPanel?.isVisible == true {
            failures.append("native \(probe.scale)x: hiding must remove the passive glow")
        }
        showWindowGlow(probe.controller, snapshot: probe.snapshot)
        let expectsGlow = probe.snapshot.placementMode == .notch
        if expectsGlow && probe.glowPanel?.isVisible != true {
            failures.append("native \(probe.scale)x: reopening must reattach the passive glow")
        }
        if !expectsGlow && probe.controller.panel.childWindows?.isEmpty == false {
            failures.append("native \(probe.scale)x: top-center must keep the passive glow window hidden")
        }
        probe.screenState.screens = [
            windowGlowScreen(mode: expectsGlow ? .topCenter : .notch)
        ]
        probe.controller.reposition()
        if expectsGlow && probe.glowPanel?.isVisible == true {
            failures.append("native \(probe.scale)x: moving to top-center must remove the stale glow window")
        }
        if !expectsGlow && probe.controller.panel.childWindows?.first?.isVisible != true {
            failures.append("native \(probe.scale)x: moving to a physical notch must restore the glow window")
        }
        if !expectsGlow && !probe.controller.revealsPhysicalContent {
            failures.append("native \(probe.scale)x: expanded content must survive moving to a physical notch")
        }
        probe.screenState.screens = []
        probe.controller.reposition()
        if probe.controller.panel.isVisible || probe.glowPanel?.isVisible == true {
            failures.append("native \(probe.scale)x: screen loss must hide both windows")
        }
    }
}

private struct GlowPixelProbe {
    let snapshot: NotchShellSnapshot
    let controller: NotchPanelController
    let raster: NotchWindowRaster
    let window: CGRect
    let shell: CGRect
    let scale: CGFloat
}

private struct GlowLifecycleProbe {
    let snapshot: NotchShellSnapshot
    let controller: NotchPanelController
    let glowPanel: NSWindow?
    let screenState: GlowScreenState
    let scale: CGFloat
}

private final class GlowScreenState {
    var screens: [ScreenSnapshot]

    init(screens: [ScreenSnapshot]) {
        self.screens = screens
    }
}
