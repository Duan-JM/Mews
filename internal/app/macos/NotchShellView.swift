import AppKit
import SwiftUI

struct NotchShellSnapshot: Equatable {
    let visibility: NotchVisibility
    let stopPulseActive: Bool
    let placementMode: OverlayPlacementMode
    let panelSize: CGSize
    let anchorSize: CGSize
    let presentationState: MewsPresentationState
    let content: NotchPanelContent
    let transitionStyle: NotchShellTransitionStyle
    let reduceTransparency: Bool
    let increaseContrast: Bool

    static let initial = NotchShellSnapshot(
        visibility: .closed,
        stopPulseActive: false,
        placementMode: .topCenter,
        panelSize: OverlayPlacementCalculator.maximumSize,
        anchorSize: .zero,
        presentationState: MewsPresentationState(event: nil),
        content: .empty,
        transitionStyle: .spatial,
        reduceTransparency: false,
        increaseContrast: false
    )

    init(
        visibility: NotchVisibility,
        stopPulseActive: Bool = false,
        placementMode: OverlayPlacementMode,
        panelSize: CGSize,
        anchorSize: CGSize,
        presentationState: MewsPresentationState,
        content: NotchPanelContent,
        transitionStyle: NotchShellTransitionStyle,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) {
        self.visibility = visibility
        self.stopPulseActive = stopPulseActive
        self.placementMode = placementMode
        self.panelSize = panelSize
        self.anchorSize = anchorSize
        self.presentationState = presentationState
        self.content = content
        self.transitionStyle = transitionStyle
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
    }
}

@MainActor
final class NotchShellViewModel: ObservableObject {
    @Published private(set) var snapshot: NotchShellSnapshot
    @Published private(set) var layout: NotchShellLayout
    private var animation: NotchShellAnimation?
    private let animationClock: () -> TimeInterval

    var geometry: NotchShellGeometry {
        return .resolved(snapshot: snapshot, layout: layout)
    }

    init(
        snapshot: NotchShellSnapshot = .initial,
        animationClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.snapshot = snapshot
        self.animationClock = animationClock
        layout = .resolved(snapshot: snapshot)
    }

    func update(snapshot: NotchShellSnapshot) {
        let target = NotchShellLayout.resolved(snapshot: snapshot)
        let changed = NotchShellLayout.resolved(snapshot: self.snapshot) != target
        let canAnimate = snapshot.transitionStyle == .spatial &&
            self.snapshot.placementMode == snapshot.placementMode &&
            self.snapshot.panelSize == snapshot.panelSize &&
            self.snapshot.anchorSize == snapshot.anchorSize
        self.snapshot = snapshot
        guard changed || !canAnimate else {
            return
        }
        let velocity = animation?.currentFrame.velocity ?? .zero
        animation?.stop()
        animation = nil
        guard canAnimate else {
            layout = target
            return
        }
        let animation = NotchShellAnimation(from: layout, to: target, velocity: velocity, clock: animationClock)
        animation.onFrame = { [weak self] frame in
            self?.layout = frame.layout
        }
        self.animation = animation
        animation.start()
    }

    func finishAnimation() {
        animation?.stop()
        animation = nil
        layout = .resolved(snapshot: snapshot)
    }
}

struct NotchShellView: View {
    @ObservedObject var model: NotchShellViewModel
    @ObservedObject var sessionListModel: SessionListPresentationModel
    let onReturnToCLI: (CLIContextPayload, SessionIdentity?) -> Void
    let onCopyCommand: (String) -> Void
    let showsGlow: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(
        model: NotchShellViewModel,
        sessionListModel: SessionListPresentationModel,
        showsGlow: Bool = true,
        onReturnToCLI: @escaping (CLIContextPayload, SessionIdentity?) -> Void = { _, _ in },
        onCopyCommand: @escaping (String) -> Void = { _ in }
    ) {
        self.model = model
        self.sessionListModel = sessionListModel
        self.showsGlow = showsGlow
        self.onReturnToCLI = onReturnToCLI
        self.onCopyCommand = onCopyCommand
    }

    var body: some View {
        let snapshot = model.snapshot
        let geometry = model.geometry
        let glow = NotchGlowPresentation.resolved(snapshot: snapshot)

        ZStack(alignment: .top) {
            Color.clear
            shell(snapshot: snapshot, geometry: geometry, glow: glow)
        }
        .frame(
            width: snapshot.panelSize.width,
            height: snapshot.panelSize.height,
            alignment: .top
        )
        .allowsHitTesting(snapshot.visibility == .expanded)
        .accessibilityElement(
            children: snapshot.visibility == .expanded ? .contain : .ignore
        )
        .accessibilityLabel(
            snapshot.visibility == .expanded
                ? "Mews status panel"
                : glow.accessibilityLabel
        )
        .accessibilityHint(accessibilityHint(for: snapshot.visibility))
    }

    @ViewBuilder
    private func shell(
        snapshot: NotchShellSnapshot,
        geometry: NotchShellGeometry,
        glow: NotchGlowPresentation
    ) -> some View {
        let layout = geometry.layout
        let surface = NotchSurfacePalette.resolved(
            placementMode: snapshot.placementMode,
            colorScheme: colorScheme,
            increaseContrast: snapshot.increaseContrast
        )
        // Keep the animated shell's identity stable when its content is replaced.
        ZStack(alignment: .top) {
            if snapshot.visibility == .expanded {
                NotchExpandedContentView(
                    snapshot: snapshot,
                    sessionListModel: sessionListModel,
                    surface: surface,
                    onReturnToCLI: onReturnToCLI,
                    onCopyCommand: onCopyCommand
                )
                .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .animation(
            opacityAnimation(for: snapshot.transitionStyle),
            value: snapshot.visibility
        )
        .frame(width: layout.width, height: layout.height, alignment: .top)
        .clipShape(geometry.shape)
        .modifier(
            NotchShellSurfaceModifier(
                snapshot: snapshot,
                geometry: geometry,
                surface: surface
            )
        )
        .background {
            if snapshot.placementMode == .notch {
                glowView(snapshot: snapshot, geometry: geometry, glow: glow)
            }
        }
    }

    @ViewBuilder
    private func glowView(
        snapshot: NotchShellSnapshot, geometry: NotchShellGeometry, glow: NotchGlowPresentation
    ) -> some View {
        if showsGlow && glow.isVisible {
            NotchGlowView(
                shape: geometry.shape, presentation: glow,
                reduceMotion: snapshot.transitionStyle == .opacityOnly,
                increaseContrast: snapshot.increaseContrast
            )
            .transition(.opacity)
        }
    }

    private func opacityAnimation(
        for style: NotchShellTransitionStyle
    ) -> Animation? {
        return .easeOut(duration: style == .spatial ? 0.12 : 0.1)
    }

    private func accessibilityHint(
        for visibility: NotchVisibility
    ) -> String {
        switch visibility {
        case .closed:
            return "Click the Mews notch glow to expand"
        case .peek:
            return "Click the pulsing Mews notch glow to expand"
        case .expanded:
            return "Mews status panel is expanded"
        }
    }
}

struct PixelStatusView: View {
    let state: MewsPresentationState
    let size: CGFloat
    var color: Color = .white

    var body: some View {
        let frame = PixelStatusLogo.animationPlan(for: state, reduceMotion: true).stableFrame
        return Image(nsImage: PixelStatusLogoRenderer.image(for: frame))
            .renderingMode(.template)
            .interpolation(.none)
            .resizable()
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
