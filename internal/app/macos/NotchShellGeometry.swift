import SwiftUI

struct NotchShellLayout: Equatable {
    private static let collapsedEdgeInset: CGFloat = 4

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
        let usesTopCenter = snapshot.placementMode == .topCenter

        switch resolvedVisibility {
        case .expanded:
            return NotchShellLayout(
                width: snapshot.panelSize.width,
                height: snapshot.panelSize.height,
                cornerRadius: usesTopCenter ? 16 : 20,
                contentTopInset: 0
            )
        case .peek:
            return NotchShellLayout(
                width: min(
                    snapshot.panelSize.width,
                    max(8, anchorWidth + (collapsedEdgeInset * 2))
                ),
                height: min(
                    snapshot.panelSize.height,
                    max(8, anchorHeight + collapsedEdgeInset)
                ),
                cornerRadius: 8,
                contentTopInset: anchorHeight
            )
        case .closed:
            return NotchShellLayout(
                width: min(
                    snapshot.panelSize.width,
                    max(8, anchorWidth + (collapsedEdgeInset * 2))
                ),
                height: min(
                    snapshot.panelSize.height,
                    max(8, anchorHeight + collapsedEdgeInset)
                ),
                cornerRadius: 8,
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
    let visibility: NotchVisibility
    let placementMode: OverlayPlacementMode
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
            visibility: resolvedVisibility,
            placementMode: snapshot.placementMode,
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

    var shape: NotchShellShape {
        return NotchShellShape(
            visibility: visibility,
            placementMode: placementMode,
            cornerRadius: layout.cornerRadius,
            anchorWidth: anchorWidth,
            anchorHeight: anchorHeight
        )
    }
}

struct NotchShellSurfaceModifier: ViewModifier {
    let snapshot: NotchShellSnapshot
    let geometry: NotchShellGeometry
    let surface: NotchSurfacePalette

    func body(content: Content) -> some View {
        content
            .background { shellBackground }
            .overlay { shellBorder }
    }

    @ViewBuilder
    private var shellBackground: some View {
        if snapshot.visibility == .expanded {
            switch NotchSurfaceTreatment.resolved(
                placementMode: snapshot.placementMode,
                reduceTransparency: snapshot.reduceTransparency,
                increaseContrast: snapshot.increaseContrast
            ) {
            case .solidBlack:
                geometry.shape.fill(Color.black)
            case .adaptiveMaterial:
                geometry.shape
                    .fill(.regularMaterial)
                    .overlay(geometry.shape.fill(surface.materialTint))
            case .opaqueFallback:
                geometry.shape.fill(surface.opaqueBackground)
            }
        }
    }

    @ViewBuilder
    private var shellBorder: some View {
        if snapshot.visibility == .expanded &&
            snapshot.placementMode == .topCenter {
            geometry.shape
                .stroke(
                    surface.foreground.opacity(surface.outerBorder),
                    lineWidth: snapshot.increaseContrast ? 1.5 : 1
                )
        }
    }
}

struct NotchShellShape: Shape {
    let visibility: NotchVisibility
    let placementMode: OverlayPlacementMode
    let cornerRadius: CGFloat
    let anchorWidth: CGFloat
    let anchorHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        switch placementMode {
        case .notch:
            if visibility != .expanded {
                return PhysicalNotchGlowShape(
                    cornerRadius: cornerRadius
                ).path(in: rect)
            }
            return TopAnchoredShellShape(
                cornerRadius: cornerRadius,
                anchorWidth: anchorWidth,
                anchorHeight: anchorHeight
            ).path(in: rect)
        case .topCenter:
            return RoundedRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            ).path(in: rect)
        }
    }

    struct PhysicalNotchGlowShape: Shape {
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
