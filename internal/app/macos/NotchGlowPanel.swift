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
    private let glowLayer = CAShapeLayer()
    private let backingLayer = CAShapeLayer()
    private var pulseKey: PulseKey?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        for shapeLayer in [glowLayer, backingLayer] {
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
        let visualRect = NotchShellShape.physicalVisualRect(in: shellRect)
        let visualShape = geometry.shape.physicalVisualShape
        let backingPath = visualShape.path(in: visualRect)
            .applying(layerTransform)
            .cgPath
        let glowPath = NotchShellShape.PhysicalNotchGlowShape(
            cornerRadius: visualShape.cornerRadius
        ).edgePath(in: visualRect)
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
            glowAlpha: snapshot.increaseContrast ? 0.78 : 0.56,
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
        for shapeLayer in [glowLayer, backingLayer] {
            shapeLayer.frame = bounds
        }
        backingLayer.path = update.backingPath
        backingLayer.isHidden = !update.showsBacking
        glowLayer.path = update.glowPath
        glowLayer.lineWidth = update.outlineWidth * 2
        glowLayer.isHidden = !update.showsGlow
        glowLayer.strokeColor = update.glowColor.withAlphaComponent(
            update.glowAlpha
        ).cgColor
        glowLayer.shadowColor = update.glowColor.cgColor
        glowLayer.shadowOpacity = 1
        glowLayer.shadowRadius = 6
        glowLayer.shadowOffset = .zero
        CATransaction.commit()
    }

    private func updatePulse(_ key: PulseKey) {
        guard pulseKey != key else {
            return
        }
        pulseKey = key
        glowLayer.removeAnimation(forKey: "mews-pulse")
        glowLayer.opacity = 1
        guard key.pulses && !key.reduceMotion else {
            return
        }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.55
        pulse.toValue = 1
        pulse.duration = 0.5
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.add(pulse, forKey: "mews-pulse")
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

private struct PulseKey: Equatable {
    let pulses: Bool
    let reduceMotion: Bool
}
