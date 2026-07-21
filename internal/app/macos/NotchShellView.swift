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
    let increaseContrast: Bool

    static let initial = NotchShellSnapshot(
        visibility: .closed,
        placementMode: .topCenter,
        panelSize: OverlayPlacementCalculator.maximumSize,
        anchorSize: .zero,
        presentationState: MewsPresentationState(event: nil),
        content: .empty,
        transitionStyle: .spatial,
        increaseContrast: false
    )
}

struct NotchShellLayout: Equatable {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let contentTopInset: CGFloat

    var contentHeight: CGFloat {
        return max(0, height - contentTopInset)
    }

    static func resolved(
        snapshot: NotchShellSnapshot,
        visibility: NotchVisibility? = nil
    ) -> NotchShellLayout {
        let resolvedVisibility = visibility ?? snapshot.visibility
        let anchorWidth = snapshot.placementMode == .notch ? snapshot.anchorSize.width : 0
        let anchorHeight = snapshot.placementMode == .notch ? snapshot.anchorSize.height : 0

        switch resolvedVisibility {
        case .expanded:
            return NotchShellLayout(
                width: snapshot.panelSize.width,
                height: snapshot.panelSize.height,
                cornerRadius: 20,
                contentTopInset: 0
            )
        case .peek:
            return NotchShellLayout(
                width: min(snapshot.panelSize.width, max(248, anchorWidth + 120)),
                height: min(snapshot.panelSize.height, max(48, anchorHeight + 44)),
                cornerRadius: 16,
                contentTopInset: anchorHeight
            )
        case .closed:
            return NotchShellLayout(
                width: min(snapshot.panelSize.width, max(152, anchorWidth + 56)),
                height: min(snapshot.panelSize.height, max(28, anchorHeight + 22)),
                cornerRadius: 12,
                contentTopInset: anchorHeight
            )
        }
    }

    func screenFrame(in panelFrame: CGRect) -> CGRect {
        return CGRect(
            x: panelFrame.midX - (width / 2),
            y: panelFrame.maxY - height,
            width: width,
            height: height
        )
    }
}

struct NotchShellGeometry {
    let layout: NotchShellLayout
    let anchorWidth: CGFloat
    let anchorHeight: CGFloat

    static func resolved(
        snapshot: NotchShellSnapshot,
        visibility: NotchVisibility? = nil
    ) -> NotchShellGeometry {
        let resolvedVisibility = visibility ?? snapshot.visibility
        let layout = NotchShellLayout.resolved(
            snapshot: snapshot,
            visibility: resolvedVisibility
        )
        let usesPhysicalNeck =
            resolvedVisibility != .expanded &&
            snapshot.placementMode == .notch
        return NotchShellGeometry(
            layout: layout,
            anchorWidth: usesPhysicalNeck ? snapshot.anchorSize.width : layout.width,
            anchorHeight: snapshot.placementMode == .notch
                ? snapshot.anchorSize.height
                : 0
        )
    }

    func screenFrame(in panelFrame: CGRect) -> CGRect {
        return layout.screenFrame(in: panelFrame)
    }

    func contains(_ screenPoint: CGPoint, in panelFrame: CGRect) -> Bool {
        let frame = screenFrame(in: panelFrame)
        guard frame.contains(screenPoint) else {
            return false
        }
        let localPoint = CGPoint(
            x: screenPoint.x - frame.minX,
            y: frame.maxY - screenPoint.y
        )
        return shape.path(
            in: CGRect(origin: .zero, size: frame.size)
        ).contains(localPoint)
    }

    var shape: TopAnchoredShellShape {
        return TopAnchoredShellShape(
            cornerRadius: layout.cornerRadius,
            anchorWidth: anchorWidth,
            anchorHeight: anchorHeight
        )
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
    let onReturnToCLI: (CLIContextPayload, SessionIdentity?) -> Void
    let onCopyCommand: (String) -> Void

    init(
        model: NotchShellViewModel,
        onReturnToCLI: @escaping (CLIContextPayload, SessionIdentity?) -> Void = { _, _ in },
        onCopyCommand: @escaping (String) -> Void = { _ in }
    ) {
        self.model = model
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
        Group {
            if snapshot.visibility == .expanded {
                NotchExpandedContentView(
                    snapshot: snapshot,
                    onReturnToCLI: onReturnToCLI,
                    onCopyCommand: onCopyCommand
                )
                .transition(.opacity)
            } else if snapshot.visibility == .peek {
                previewContent(snapshot: snapshot, layout: layout)
                    .transition(.opacity)
            } else {
                compactContent(snapshot: snapshot, layout: layout)
                    .transition(.opacity)
            }
        }
        .frame(width: layout.width, height: layout.height, alignment: .top)
        .background(
            geometry.shape
                .fill(Color.black)
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
        layout: NotchShellLayout
    ) -> some View {
        let copy = NotchStatusCopy.resolved(status: snapshot.presentationState.status)
        let palette = NotchContrastPalette.resolved(
            increaseContrast: snapshot.increaseContrast
        )

        return statusBand(layout: layout) {
            HStack(spacing: 7) {
                PixelStatusView(state: snapshot.presentationState, size: 14)
                    .opacity(max(0.82, palette.badgeText))
                Text(copy.code)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(Color.white.opacity(max(0.82, palette.badgeText)))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
        }
    }

    private func previewContent(
        snapshot: NotchShellSnapshot,
        layout: NotchShellLayout
    ) -> some View {
        let copy = NotchStatusCopy.resolved(status: snapshot.presentationState.status)
        let palette = NotchContrastPalette.resolved(
            increaseContrast: snapshot.increaseContrast
        )

        return statusBand(layout: layout) {
            HStack(spacing: 10) {
                PixelStatusView(state: snapshot.presentationState, size: 20)
                    .opacity(max(0.88, palette.primaryText))
                VStack(alignment: .leading, spacing: 1) {
                    Text(copy.code)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.9)
                        .foregroundStyle(Color.white.opacity(max(0.78, palette.badgeText)))
                    Text(copy.detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(max(0.9, palette.primaryText)))
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

    var body: some View {
        let frame = PixelStatusLogo.animationPlan(for: state, reduceMotion: true).stableFrame
        return Image(nsImage: PixelStatusLogoRenderer.image(for: frame))
            .renderingMode(.template)
            .interpolation(.none)
            .resizable()
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct TopAnchoredShellShape: Shape {
    let cornerRadius: CGFloat
    let anchorWidth: CGFloat
    let anchorHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
        let neckWidth = min(max(anchorWidth, 0), rect.width)
        let neckLeft = rect.midX - (neckWidth / 2)
        let neckRight = rect.midX + (neckWidth / 2)
        let shoulderStart = min(
            max(anchorHeight, 0),
            max(0, rect.height - radius - 12)
        )
        let shoulderEnd = min(rect.height - radius, shoulderStart + 12)

        var path = Path()
        path.move(to: CGPoint(x: neckLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: neckRight, y: rect.minY))
        path.addLine(to: CGPoint(x: neckRight, y: shoulderStart))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: shoulderEnd),
            control1: CGPoint(x: neckRight, y: shoulderEnd),
            control2: CGPoint(x: rect.maxX, y: shoulderStart)
        )
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
        path.addLine(to: CGPoint(x: rect.minX, y: shoulderEnd))
        path.addCurve(
            to: CGPoint(x: neckLeft, y: shoulderStart),
            control1: CGPoint(x: rect.minX, y: shoulderStart),
            control2: CGPoint(x: neckLeft, y: shoulderEnd)
        )
        path.closeSubpath()
        return path
    }
}
