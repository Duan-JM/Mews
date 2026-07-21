import AppKit
import SwiftUI

struct NotchShellSnapshot: Equatable {
    let visibility: NotchVisibility
    let placementMode: OverlayPlacementMode
    let panelSize: CGSize
    let anchorSize: CGSize
    let presentationState: MewsPresentationState
    let transitionStyle: NotchShellTransitionStyle

    static let initial = NotchShellSnapshot(
        visibility: .closed,
        placementMode: .topCenter,
        panelSize: OverlayPlacementCalculator.maximumSize,
        anchorSize: .zero,
        presentationState: MewsPresentationState(event: nil),
        transitionStyle: .spatial
    )
}

struct NotchShellLayout: Equatable {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    static func resolved(snapshot: NotchShellSnapshot) -> NotchShellLayout {
        switch snapshot.visibility {
        case .expanded:
            return NotchShellLayout(
                width: snapshot.panelSize.width,
                height: snapshot.panelSize.height,
                cornerRadius: 20
            )
        case .closed, .peek:
            let anchorWidth = snapshot.placementMode == .notch ? snapshot.anchorSize.width : 0
            let width = min(snapshot.panelSize.width, max(168, anchorWidth + 96))
            let anchorHeight = snapshot.placementMode == .notch ? snapshot.anchorSize.height : 0
            return NotchShellLayout(
                width: width,
                height: max(46, anchorHeight + 14),
                cornerRadius: 14
            )
        }
    }
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

    var body: some View {
        let snapshot = model.snapshot
        let layout = NotchShellLayout.resolved(snapshot: snapshot)

        ZStack(alignment: .top) {
            Color.clear
            shell(snapshot: snapshot, layout: layout)
        }
        .frame(
            width: snapshot.panelSize.width,
            height: snapshot.panelSize.height,
            alignment: .top
        )
        .allowsHitTesting(snapshot.visibility == .expanded)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.presentationState.accessibilityLabel)
        .accessibilityHint(accessibilityHint(for: snapshot.visibility))
    }

    @ViewBuilder
    private func shell(
        snapshot: NotchShellSnapshot,
        layout: NotchShellLayout
    ) -> some View {
        Group {
            if snapshot.visibility == .expanded {
                expandedContent(state: snapshot.presentationState)
            } else {
                peekContent(state: snapshot.presentationState)
            }
        }
        .frame(width: layout.width, height: layout.height, alignment: .top)
        .background(
            TopAnchoredShellShape(cornerRadius: layout.cornerRadius)
                .fill(Color.black)
        )
        .opacity(snapshot.visibility == .closed ? 0 : 1)
        .animation(
            spatialAnimation(for: snapshot.transitionStyle),
            value: layout
        )
        .animation(
            opacityAnimation(for: snapshot.transitionStyle),
            value: snapshot.visibility
        )
    }

    private func peekContent(
        state: MewsPresentationState
    ) -> some View {
        HStack(spacing: 10) {
            statusImage(state: state, size: 24)
            Text(state.accessibilityLabel)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func expandedContent(
        state: MewsPresentationState
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                statusImage(state: state, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mews")
                        .font(.system(size: 14, weight: .semibold))
                    Text(state.accessibilityLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.72))
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Spacer()

            Text("Compact agent status")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.62))
                .padding(.bottom, 20)
        }
        .foregroundStyle(Color.white)
    }

    private func statusImage(
        state: MewsPresentationState,
        size: CGFloat
    ) -> some View {
        let frame = PixelStatusLogo.animationPlan(for: state, reduceMotion: true).stableFrame
        return Image(nsImage: PixelStatusLogoRenderer.image(for: frame))
            .renderingMode(.template)
            .interpolation(.none)
            .resizable()
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
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
        return style == .spatial ? .easeOut(duration: 0.12) : nil
    }

    private func accessibilityHint(
        for visibility: NotchVisibility
    ) -> String {
        switch visibility {
        case .closed:
            return "Mews status panel is closed"
        case .peek:
            return "Mews status preview"
        case .expanded:
            return "Mews status panel is expanded"
        }
    }
}

private struct TopAnchoredShellShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}
