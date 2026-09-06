import SwiftUI

struct SessionSwipeActionGeometry: Equatable {
    let trackWidth: CGFloat

    init(trackWidth: CGFloat) {
        self.trackWidth = max(0, trackWidth)
    }

    var buttonWidth: CGFloat {
        return max(0, trackWidth - 2 * SessionSwipeMetrics.actionInset)
    }

    var height: CGFloat {
        return min(buttonWidth, SessionRowLayout.actionButtonHeight)
    }

    var cornerRadius: CGFloat {
        let diameter = SessionRowLayout.actionButtonHeight
        let width = buttonWidth
        let radius: CGFloat
        if width <= diameter {
            radius = width / 2
        } else {
            let progress = min(1, (width - diameter) / (SessionRowLayout.actionButtonWidth - diameter))
            radius = diameter / 2 + (SessionRowLayout.actionButtonCornerRadius - diameter / 2) * progress
        }
        return radius
    }

    var verticalOffset: CGFloat {
        return -SessionRowLayout.contentBottomInset / 2
    }

    var labelOpacity: Double {
        let diameter = SessionRowLayout.actionButtonHeight
        return min(1, max(0, (buttonWidth - diameter) / (SessionRowLayout.actionButtonWidth - diameter)))
    }
}

enum SessionSwipeMotion {
    static let response = 0.28
    static let dampingFraction = 0.86

    static func fullSwipe(_ style: NotchShellTransitionStyle) -> Animation? {
        guard style == .spatial else {
            return nil
        }
        return .spring(response: response, dampingFraction: dampingFraction)
    }
}

struct SessionSwipeActionView: View, Animatable {
    var geometry: SessionSwipeActionGeometry
    let isFullSwipe: Bool
    let labelOpacity: Double
    let snapshot: NotchShellSnapshot
    let palette: NotchContrastPalette
    let onHide: () -> Void

    // Derive the circle and label from the interpolated width, including interrupted springs.
    var animatableData: CGFloat {
        get { geometry.trackWidth }
        set { geometry = SessionSwipeActionGeometry(trackWidth: newValue) }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            trackBackground
                .allowsHitTesting(false)
            hideButton
                .offset(x: -SessionSwipeMetrics.actionInset, y: geometry.verticalOffset)
        }
        .frame(width: geometry.trackWidth, height: SessionRowLayout.rowHeight)
        .clipped()
    }

    @ViewBuilder
    private var trackBackground: some View {
        if NotchSurfaceTreatment.resolved(
            placementMode: snapshot.placementMode,
            reduceTransparency: snapshot.reduceTransparency,
            increaseContrast: snapshot.increaseContrast
        ) == .adaptiveMaterial {
            Rectangle()
                .fill(.regularMaterial)
                .overlay(Color.black.opacity(0.04))
        } else {
            Color.black.opacity(snapshot.increaseContrast ? 0.12 : 0.06)
        }
    }

    private var hideButton: some View {
        Button(action: onHide) {
            RoundedRectangle(cornerRadius: geometry.cornerRadius)
                .fill(Self.danger)
                .overlay(
                    RoundedRectangle(cornerRadius: geometry.cornerRadius)
                        .strokeBorder(
                            Color.white.opacity(palette.border),
                            lineWidth: 1
                        )
                )
                .overlay {
                    Text("HIDE")
                        .font(.system(
                            size: SessionRowLayout.actionFontSize,
                            weight: .semibold,
                            design: .monospaced
                        ))
                        .tracking(SessionRowLayout.actionTracking)
                        .foregroundStyle(Color.white)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: isFullSwipe ? .leading : .center)
                        .padding(.horizontal, 10)
                        .opacity(geometry.labelOpacity * labelOpacity)
                        // The label changes alignment immediately while the button itself stretches.
                        .transaction { $0.animation = nil }
                }
                .frame(width: geometry.buttonWidth, height: geometry.height)
                .clipped()
        }
        .buttonStyle(SessionHideActionButtonStyle(transitionStyle: snapshot.transitionStyle))
        .accessibilityHidden(true)
    }

    private static let danger = Color(
        red: 200.0 / 255.0,
        green: 15.0 / 255.0,
        blue: 40.0 / 255.0
    )
}

private struct SessionHideActionButtonStyle: ButtonStyle {
    let transitionStyle: NotchShellTransitionStyle

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(
                configuration.isPressed && transitionStyle == .spatial ? 0.98 : 1,
                anchor: .trailing
            )
            .animation(
                transitionStyle == .spatial ? .easeOut(duration: 0.08) : nil,
                value: configuration.isPressed
            )
    }
}
