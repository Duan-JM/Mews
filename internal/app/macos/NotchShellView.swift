import AppKit
import SwiftUI

struct NotchShellSnapshot: Equatable {
    let visibility: NotchVisibility
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
        placementMode: .topCenter,
        panelSize: OverlayPlacementCalculator.maximumSize,
        anchorSize: .zero,
        presentationState: MewsPresentationState(event: nil),
        content: .empty,
        transitionStyle: .spatial,
        reduceTransparency: false,
        increaseContrast: false
    )
}

@MainActor
final class NotchShellViewModel: ObservableObject {
    @Published private(set) var snapshot: NotchShellSnapshot

    init(snapshot: NotchShellSnapshot = .initial) {
        self.snapshot = snapshot
    }

    func update(snapshot: NotchShellSnapshot) {
        self.snapshot = snapshot
    }
}

struct NotchShellView: View {
    @ObservedObject var model: NotchShellViewModel
    @ObservedObject var sessionListModel: SessionListPresentationModel
    let onReturnToCLI: (CLIContextPayload, SessionIdentity?) -> Void
    let onCopyCommand: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme

    init(
        model: NotchShellViewModel,
        sessionListModel: SessionListPresentationModel,
        onReturnToCLI: @escaping (CLIContextPayload, SessionIdentity?) -> Void = { _, _ in },
        onCopyCommand: @escaping (String) -> Void = { _ in }
    ) {
        self.model = model
        self.sessionListModel = sessionListModel
        self.onReturnToCLI = onReturnToCLI
        self.onCopyCommand = onCopyCommand
    }

    var body: some View {
        let snapshot = model.snapshot
        let geometry = NotchShellGeometry.resolved(snapshot: snapshot)

        ZStack(alignment: .top) {
            Color.clear
            shell(snapshot: snapshot, geometry: geometry)
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
                : snapshot.presentationState.accessibilityLabel
        )
        .accessibilityHint(accessibilityHint(for: snapshot.visibility))
    }

    @ViewBuilder
    private func shell(
        snapshot: NotchShellSnapshot,
        geometry: NotchShellGeometry
    ) -> some View {
        let layout = geometry.layout
        let surface = NotchSurfacePalette.resolved(
            placementMode: snapshot.placementMode,
            colorScheme: colorScheme,
            increaseContrast: snapshot.increaseContrast
        )
        Group {
            if snapshot.visibility == .expanded {
                NotchExpandedContentView(
                    snapshot: snapshot,
                    sessionListModel: sessionListModel,
                    surface: surface,
                    onReturnToCLI: onReturnToCLI,
                    onCopyCommand: onCopyCommand
                )
                .transition(.opacity)
            } else if snapshot.visibility == .peek {
                previewContent(
                    snapshot: snapshot,
                    layout: layout,
                    surface: surface
                )
                    .transition(.opacity)
            } else {
                compactContent(
                    snapshot: snapshot,
                    layout: layout,
                    surface: surface
                )
                    .transition(.opacity)
            }
        }
        .frame(width: layout.width, height: layout.height, alignment: .top)
        .modifier(
            NotchShellSurfaceModifier(
                snapshot: snapshot,
                geometry: geometry,
                surface: surface
            )
        )
        .animation(
            spatialAnimation(for: snapshot.transitionStyle),
            value: layout
        )
        .animation(
            opacityAnimation(for: snapshot.transitionStyle),
            value: snapshot.visibility
        )
    }

    private func compactContent(
        snapshot: NotchShellSnapshot,
        layout: NotchShellLayout,
        surface: NotchSurfacePalette
    ) -> some View {
        let copy = NotchStatusCopy.resolved(status: snapshot.presentationState.status)
        let palette = NotchContrastPalette.resolved(
            increaseContrast: snapshot.increaseContrast
        )

        return statusBand(layout: layout) {
            HStack(spacing: 7) {
                PixelStatusView(
                    state: snapshot.presentationState,
                    size: 14,
                    color: surface.foreground
                )
                    .opacity(max(0.82, palette.badgeText))
                Text(copy.code)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(
                        surface.foreground.opacity(max(0.82, palette.badgeText))
                    )
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
        }
    }

    private func previewContent(
        snapshot: NotchShellSnapshot,
        layout: NotchShellLayout,
        surface: NotchSurfacePalette
    ) -> some View {
        let copy = NotchStatusCopy.resolved(status: snapshot.presentationState.status)
        let palette = NotchContrastPalette.resolved(
            increaseContrast: snapshot.increaseContrast
        )

        return statusBand(layout: layout) {
            HStack(spacing: 10) {
                PixelStatusView(
                    state: snapshot.presentationState,
                    size: 20,
                    color: surface.foreground
                )
                    .opacity(max(0.88, palette.primaryText))
                VStack(alignment: .leading, spacing: 1) {
                    Text(copy.code)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.9)
                        .foregroundStyle(
                            surface.foreground.opacity(max(0.78, palette.badgeText))
                        )
                    Text(copy.detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(
                            surface.foreground.opacity(max(0.9, palette.primaryText))
                        )
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func statusBand<Content: View>(
        layout: NotchShellLayout,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: layout.contentTopInset)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: layout.width, height: layout.height, alignment: .top)
    }

    private func spatialAnimation(
        for style: NotchShellTransitionStyle
    ) -> Animation? {
        guard style == .spatial else {
            return nil
        }
        return .spring(response: 0.3, dampingFraction: 0.88)
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
            return "Click the compact Mews status to expand"
        case .peek:
            return "Click the Mews status preview to expand"
        case .expanded:
            return "Mews status panel is expanded"
        }
    }
}

struct NotchStatusCopy: Equatable {
    let code: String
    let detail: String

    static func resolved(status: MewsPresentationStatus) -> NotchStatusCopy {
        switch status {
        case .idle:
            return NotchStatusCopy(code: "IDLE", detail: "Standing by")
        case .running:
            return NotchStatusCopy(code: "RUN", detail: "Agent running")
        case .needsInput:
            return NotchStatusCopy(code: "ASK", detail: "Needs input")
        case .done:
            return NotchStatusCopy(code: "DONE", detail: "Task complete")
        case .failed:
            return NotchStatusCopy(code: "FAIL", detail: "Task failed")
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
