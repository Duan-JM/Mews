import SwiftUI

struct NotchExpandedContentView: View {
    let snapshot: NotchShellSnapshot
    @ObservedObject var sessionListModel: SessionListPresentationModel
    let surface: NotchSurfacePalette
    let onReturnToCLI: (CLIContextPayload, SessionIdentity?) -> Void
    let onCopyCommand: (String) -> Void

    private var palette: NotchContrastPalette {
        return .resolved(increaseContrast: snapshot.increaseContrast)
    }

    private var headerLayout: NotchExpandedHeaderLayout {
        return NotchExpandedHeaderLayout.resolved(
            placementMode: snapshot.placementMode,
            anchorSize: snapshot.anchorSize,
            sessionCount: sessionListModel.snapshot.rows.count
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let errorMessage = sessionListModel.snapshot.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.35)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                    .transition(.opacity)
                    .accessibilityLabel(errorMessage)
            }
            if let health = snapshot.content.health {
                NotchHealthRowView(
                    health: health,
                    transitionStyle: snapshot.transitionStyle,
                    palette: palette,
                    surface: surface,
                    onCopyCommand: onCopyCommand
                )
                    .padding(.top, 5)
            }
            if sessionListModel.snapshot.rows.isEmpty {
                emptyContent
            } else {
                NotchSessionContentView(
                    snapshot: snapshot,
                    sessionListModel: sessionListModel,
                    palette: palette,
                    surface: surface,
                    onReturnToCLI: onReturnToCLI,
                    onCopyCommand: onCopyCommand
                )
            }
        }
        .padding(.horizontal, 18)
        .foregroundStyle(surface.foreground)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            PixelStatusView(
                state: snapshot.presentationState,
                size: 28,
                color: surface.foreground
            )
            Spacer()
            Text(topBarLabel)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(surface.foreground.opacity(palette.badgeText))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            surface.foreground.opacity(palette.border),
                            lineWidth: 1
                        )
                )
        }
        .frame(height: 28)
        .padding(.top, headerLayout.topInset)
    }

    private var emptyContent: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            Text("NO ACTIVE SESSIONS")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(surface.foreground.opacity(palette.primaryText))
            Text("Recent events remain in mw history")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(surface.foreground.opacity(palette.secondaryText))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
    }

    private var topBarLabel: String {
        let count = sessionListModel.snapshot.rows.count
        return count == 0 ? "NO ACTIVE" : "\(count) ACTIVE"
    }
}

struct NotchExpandedHeaderLayout: Equatable {
    static let preferredTopInset: CGFloat = 14
    static let notchClearance: CGFloat = 6
    // The fixed panel fits three complete session rows before scrolling.
    static let visibleSessionCapacity = 3

    let topInset: CGFloat

    static func resolved(
        placementMode: OverlayPlacementMode,
        anchorSize: CGSize,
        sessionCount: Int
    ) -> NotchExpandedHeaderLayout {
        guard placementMode == .notch,
              anchorSize.height > 0,
              sessionCount > visibleSessionCapacity else {
            return NotchExpandedHeaderLayout(
                topInset: preferredTopInset
            )
        }

        return NotchExpandedHeaderLayout(
            topInset: max(
                preferredTopInset,
                anchorSize.height + notchClearance
            )
        )
    }
}
