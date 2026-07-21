import SwiftUI

struct NotchExpandedContentView: View {
    let snapshot: NotchShellSnapshot
    let onReturnToCLI: (CLIContextPayload) -> Void
    let onCopyCommand: (String) -> Void

    private var palette: NotchContrastPalette {
        return .resolved(increaseContrast: snapshot.increaseContrast)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            currentSummary
            rule
                .padding(.top, 9)
            recentEvents
                .padding(.top, 7)
            Spacer(minLength: 6)
            actions
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 18)
        .foregroundStyle(Color.white)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            PixelStatusView(state: snapshot.presentationState, size: 28)
            Spacer()
            Text(currentStatusLabel.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Color.white.opacity(palette.badgeText))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.white.opacity(palette.border), lineWidth: 1)
                )
        }
        .frame(height: 28)
        .padding(.top, 14)
    }

    private var currentSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(currentSourceLabel.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                if let metadata = snapshot.content.current?.metadataLine {
                    Text(metadata.uppercased())
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(palette.metadataText))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Text(snapshot.content.current?.message ?? "No current agent activity")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(palette.primaryText))
                .lineLimit(1)
        }
        .padding(.top, 9)
        .accessibilityElement(children: .combine)
    }

    private var recentEvents: some View {
        VStack(spacing: 4) {
            if snapshot.content.recent.isEmpty {
                HStack {
                    Text("NO EARLIER PRIMARY EVENTS")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(Color.white.opacity(palette.mutedText))
                    Spacer()
                }
                .frame(height: 16)
            } else {
                ForEach(Array(snapshot.content.recent.enumerated()), id: \.offset) { _, event in
                    recentRow(event)
                }
            }
        }
    }

    private func recentRow(_ event: NotchEventSummary) -> some View {
        HStack(spacing: 8) {
            Text(event.statusLabel.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(Color.white.opacity(statusOpacity(event.presentationStatus)))
                .frame(width: 72, alignment: .leading)
            Text(event.message)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.white.opacity(palette.secondaryText))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 16)
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("RETURN TO CLI") {
                if let context = snapshot.content.actionableContext {
                    onReturnToCLI(context)
                }
            }
            .buttonStyle(
                NotchActionButtonStyle(
                    emphasis: true,
                    transitionStyle: snapshot.transitionStyle,
                    palette: palette
                )
            )
            .disabled(snapshot.content.actionableContext == nil)
            .accessibilityHint("Returns to the validated terminal context")

            Button("COPY RETURN COMMAND") {
                if let command = snapshot.content.returnCommand {
                    onCopyCommand(command)
                }
            }
            .buttonStyle(
                NotchActionButtonStyle(
                    emphasis: false,
                    transitionStyle: snapshot.transitionStyle,
                    palette: palette
                )
            )
            .disabled(snapshot.content.returnCommand == nil)
            .accessibilityHint("Copies the local Mews history command")
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.white.opacity(palette.separator))
            .frame(height: 1)
    }

    private var currentSourceLabel: String {
        return snapshot.content.current?.sourceLabel ?? "Mews"
    }

    private var currentStatusLabel: String {
        return snapshot.content.current?.statusLabel ?? snapshot.presentationState.status.panelLabel
    }

    private func statusOpacity(_ status: MewsPresentationStatus) -> Double {
        let opacity: Double
        switch status {
        case .needsInput, .failed:
            opacity = 0.92
        case .done:
            opacity = 0.76
        case .running:
            opacity = 0.64
        case .idle:
            opacity = 0.42
        }
        return max(opacity, palette.statusFloor)
    }
}

private struct NotchActionButtonStyle: ButtonStyle {
    let emphasis: Bool
    let transitionStyle: NotchShellTransitionStyle
    let palette: NotchContrastPalette

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: 1)
            )
            .opacity(configuration.isPressed && transitionStyle == .opacityOnly ? 0.72 : 1)
            .scaleEffect(pressedScale(configuration: configuration))
            .animation(buttonAnimation, value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        if !isEnabled {
            return Color.white.opacity(palette.disabledText)
        }
        return emphasis ? .black : .white
    }

    private var backgroundColor: Color {
        if !isEnabled {
            return Color.white.opacity(palette.disabledSurface)
        }
        return emphasis ? .white : Color.white.opacity(0.08)
    }

    private var borderColor: Color {
        if !isEnabled {
            return Color.white.opacity(palette.disabledBorder)
        }
        return emphasis ? .white : Color.white.opacity(palette.border)
    }

    private var buttonAnimation: Animation? {
        return transitionStyle == .spatial ? .easeOut(duration: 0.08) : nil
    }

    private func pressedScale(configuration: Configuration) -> CGFloat {
        guard isEnabled,
              configuration.isPressed,
              transitionStyle == .spatial else {
            return 1
        }
        return 0.98
    }
}

private extension MewsPresentationStatus {
    var panelLabel: String {
        switch self {
        case .idle:
            return "Idle"
        case .running:
            return "Running"
        case .needsInput:
            return "Needs Input"
        case .done:
            return "Done"
        case .failed:
            return "Failed"
        }
    }
}
