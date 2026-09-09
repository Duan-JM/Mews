import AppKit
import SwiftUI

@MainActor
final class NotchGlowPanel: NSPanel {
    static let margin: CGFloat = 32

    init(model: NotchShellViewModel) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .statusBar
        collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: NotchGlowWindowView(model: model))
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

    func show(below window: NSWindow) {
        // AppKit detaches child windows when they are ordered out.
        if parent !== window {
            window.addChildWindow(self, ordered: .below)
        }
        order(.below, relativeTo: window.windowNumber)
    }
}

private struct NotchGlowWindowView: View {
    @ObservedObject var model: NotchShellViewModel

    var body: some View {
        let snapshot = model.snapshot
        let geometry = model.geometry
        let glow = NotchGlowPresentation.resolved(snapshot: snapshot)
        ZStack(alignment: .top) {
            Color.clear
            if snapshot.placementMode == .notch && glow.isVisible {
                NotchGlowView(
                    shape: geometry.shape, presentation: glow,
                    reduceMotion: snapshot.transitionStyle == .opacityOnly,
                    increaseContrast: snapshot.increaseContrast
                )
                .frame(width: geometry.layout.width, height: geometry.layout.height)
            }
        }
        .frame(width: snapshot.panelSize.width, height: snapshot.panelSize.height)
        .padding(.horizontal, NotchGlowPanel.margin)
        .padding(.bottom, NotchGlowPanel.margin)
        .padding(.top, snapshot.placementMode == .notch ? 0 : NotchGlowPanel.margin)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
