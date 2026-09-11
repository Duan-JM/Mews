import AppKit
import QuartzCore

@MainActor
final class NotchGlowPanel: NSPanel {
    static let margin: CGFloat = 32

    private let visualView = NotchShellVisualView()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .statusBar
        collectionBehavior = [
            .fullScreenAuxiliary,
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle
        ]
        contentView = visualView
        setAccessibilityElement(false)
    }

    func place(around frame: CGRect, mode: OverlayPlacementMode) {
        let topMargin = mode == .notch ? 0 : Self.margin
        setFrame(
            CGRect(
                x: frame.minX - Self.margin,
                y: frame.minY - Self.margin,
                width: frame.width + Self.margin * 2,
                height: frame.height + Self.margin + topMargin
            ),
            display: false
        )
    }

    func update(snapshot: NotchShellSnapshot, geometry: NotchShellGeometry) {
        visualView.update(snapshot: snapshot, geometry: geometry)
    }

    func show(below window: NSWindow) {
        // AppKit detaches child windows when they are ordered out.
        if parent !== window {
            window.addChildWindow(self, ordered: .below)
        }
        order(.below, relativeTo: window.windowNumber)
    }
}

@MainActor
private final class NotchShellVisualView: NSView {
    private let farGlowLayer = CAShapeLayer()
    private let nearGlowLayer = CAShapeLayer()
    private let glowLayer = CAShapeLayer()
    private let backingLayer = CAShapeLayer()
    private var pulseKey: PulseKey?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        for shapeLayer in [farGlowLayer, nearGlowLayer, glowLayer, backingLayer] {
            shapeLayer.fillColor = NSColor.clear.cgColor
            shapeLayer.lineCap = .round
            shapeLayer.lineJoin = .round
            layer?.addSublayer(shapeLayer)
        }
        backingLayer.fillColor = NSColor.black.cgColor
        backingLayer.strokeColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(snapshot: NotchShellSnapshot, geometry: NotchShellGeometry) {
        let presentation = NotchGlowPresentation.resolved(snapshot: snapshot)
        let shellRect = CGRect(
            x: (bounds.width - geometry.layout.width) / 2,
            y: 0,
            width: geometry.layout.width,
            height: geometry.layout.height
        )
        let layerTransform = CGAffineTransform(
            a: 1,
            b: 0,
            c: 0,
            d: -1,
            tx: 0,
            ty: bounds.height
        )
        let backingPath = geometry.shape.path(in: shellRect)
            .applying(layerTransform)
            .cgPath
        let glowPath = NotchShellShape.PhysicalNotchGlowShape(
            cornerRadius: geometry.layout.cornerRadius
        ).edgePath(in: shellRect)
            .applying(layerTransform)
            .cgPath
        let glowColor = color(for: presentation.signal)
        let outlineWidth = NotchShellShape.outlineWidth(
            increaseContrast: snapshot.increaseContrast
        )
        let showsBacking =
            snapshot.placementMode == .notch &&
            (snapshot.visibility == .expanded || presentation.isVisible)
        let showsGlow = snapshot.placementMode == .notch && presentation.isVisible

        updateLayers(VisualLayerUpdate(
            backingPath: backingPath,
            glowPath: glowPath,
            glowColor: glowColor,
            glowAlpha: snapshot.increaseContrast ? 1 : 0.82,
            outlineWidth: outlineWidth,
            showsBacking: showsBacking,
            showsGlow: showsGlow
        ))
        updatePulse(
            PulseKey(
                pulses: showsGlow && presentation.pulses,
                reduceMotion: snapshot.transitionStyle == .opacityOnly
            )
        )
    }

    private func updateLayers(_ update: VisualLayerUpdate) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shapeLayer in [farGlowLayer, nearGlowLayer, glowLayer, backingLayer] {
            shapeLayer.frame = bounds
        }
        backingLayer.path = update.backingPath
        backingLayer.isHidden = !update.showsBacking
        for shapeLayer in [farGlowLayer, nearGlowLayer, glowLayer] {
            shapeLayer.path = update.glowPath
            shapeLayer.lineWidth = update.outlineWidth * 2
            shapeLayer.isHidden = !update.showsGlow
        }
        glowLayer.strokeColor = update.glowColor.withAlphaComponent(
            update.glowAlpha
        ).cgColor
        configureShadow(
            farGlowLayer,
            style: GlowShadowStyle(
                color: update.glowColor,
                lineWidth: update.outlineWidth * 2 + 16,
                strokeOpacity: 0.12,
                shadowOpacity: 0.48,
                radius: 11
            )
        )
        configureShadow(
            nearGlowLayer,
            style: GlowShadowStyle(
                color: update.glowColor,
                lineWidth: update.outlineWidth * 2 + 8,
                strokeOpacity: 0.24,
                shadowOpacity: 0.9,
                radius: 6
            )
        )
        CATransaction.commit()
    }

    private func configureShadow(
        _ shapeLayer: CAShapeLayer,
        style: GlowShadowStyle
    ) {
        shapeLayer.lineWidth = style.lineWidth
        shapeLayer.strokeColor = style.color.withAlphaComponent(
            style.strokeOpacity
        ).cgColor
        shapeLayer.shadowColor = style.color.cgColor
        shapeLayer.shadowOpacity = style.shadowOpacity
        shapeLayer.shadowRadius = style.radius
        shapeLayer.shadowOffset = .zero
    }

    private func updatePulse(_ key: PulseKey) {
        guard pulseKey != key else {
            return
        }
        pulseKey = key
        for shapeLayer in [farGlowLayer, nearGlowLayer, glowLayer] {
            shapeLayer.removeAnimation(forKey: "mews-pulse")
            shapeLayer.opacity = 1
            guard key.pulses && !key.reduceMotion else {
                continue
            }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.55
            pulse.toValue = 1
            pulse.duration = 0.5
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shapeLayer.add(pulse, forKey: "mews-pulse")
        }
    }

    private func color(for signal: NotchGlowSignal) -> NSColor {
        switch signal {
        case .running:
            return NSColor(calibratedRed: 0.22, green: 1, blue: 0.46, alpha: 1)
        case .attention, .stopped:
            return NSColor(calibratedRed: 1, green: 0.16, blue: 0.24, alpha: 1)
        case .hidden:
            return .clear
        }
    }
}

private struct VisualLayerUpdate {
    let backingPath: CGPath
    let glowPath: CGPath
    let glowColor: NSColor
    let glowAlpha: CGFloat
    let outlineWidth: CGFloat
    let showsBacking: Bool
    let showsGlow: Bool
}

private struct GlowShadowStyle {
    let color: NSColor
    let lineWidth: CGFloat
    let strokeOpacity: CGFloat
    let shadowOpacity: Float
    let radius: CGFloat
}

private struct PulseKey: Equatable {
    let pulses: Bool
    let reduceMotion: Bool
}
