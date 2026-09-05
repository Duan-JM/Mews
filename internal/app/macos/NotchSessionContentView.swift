import SwiftUI

struct NotchSessionContentView: View {
    let snapshot: NotchShellSnapshot
    let palette: NotchContrastPalette
    let surface: NotchSurfacePalette
    let onReturnToCLI: (CLIContextPayload, SessionIdentity?) -> Void
    let onCopyCommand: (String) -> Void

    var body: some View {
        SessionListScrollContainer {
            LazyVStack(spacing: 0) {
                ForEach(snapshot.content.sessionRows, id: \.identity) { row in
                    sessionRow(row)
                        .frame(height: 42)
                        .overlay(rule, alignment: .bottom)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 7)
        .accessibilityLabel("Active sessions")
    }

    private func sessionRow(_ row: SessionPresentationRow) -> some View {
        HStack(spacing: 7) {
            Text(row.statusCode)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.3)
                .foregroundStyle(surface.foreground.opacity(statusOpacity(row.status)))
                .frame(width: 34, alignment: .leading)
            sessionIdentity(row)
            returnButton(row)
            copyButton(row)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.accessibilityLabel)
    }

    private func sessionIdentity(_ row: SessionPresentationRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.primaryLabel)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(surface.foreground.opacity(palette.primaryText))
                .lineLimit(1)
            Text("SESSION \(row.sessionLabel)  ·  \(row.statusLabel.uppercased())")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .tracking(0.35)
                .foregroundStyle(surface.foreground.opacity(palette.metadataText))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func returnButton(_ row: SessionPresentationRow) -> some View {
        Button(row.returnActionLabel) {
            if let context = row.returnContext {
                onReturnToCLI(context, row.identity)
            }
        }
        .buttonStyle(
            NotchRowActionButtonStyle(
                emphasis: true,
                transitionStyle: snapshot.transitionStyle,
                palette: palette,
                surface: surface
            )
        )
        .frame(width: 62)
        .disabled(row.returnContext == nil)
        .accessibilityLabel("\(row.returnActionDescription) session \(row.sessionLabel)")
        .accessibilityHint(
            row.returnContext?.codexAppURL == nil
                ? "Returns to the validated terminal context"
                : "Opens the matching session in Codex"
        )
    }

    private func copyButton(_ row: SessionPresentationRow) -> some View {
        Button("COPY") {
            if let command = row.returnCommand {
                onCopyCommand(command)
            }
        }
        .buttonStyle(
            NotchRowActionButtonStyle(
                emphasis: false,
                transitionStyle: snapshot.transitionStyle,
                palette: palette,
                surface: surface
            )
        )
        .frame(width: 44)
        .disabled(row.returnCommand == nil)
        .accessibilityLabel(
            "Copy return command for \(row.sourceLabel) session \(row.sessionLabel)"
        )
    }

    private var rule: some View {
        Rectangle()
            .fill(surface.foreground.opacity(palette.separator))
            .frame(height: 1)
    }

    private func statusOpacity(_ status: SessionStatus) -> Double {
        switch status {
        case .needsInput, .failed:
            return max(0.92, palette.statusFloor)
        case .done:
            return max(0.76, palette.statusFloor)
        case .running:
            return max(0.64, palette.statusFloor)
        case .idle:
            return max(0.42, palette.statusFloor)
        }
    }
}

struct NotchHealthRowView: View {
    let health: RuntimeHealthPresentation
    let transitionStyle: NotchShellTransitionStyle
    let palette: NotchContrastPalette
    let surface: NotchSurfacePalette
    let onCopyCommand: (String) -> Void

    var body: some View {
        HStack(spacing: 7) {
            Text(health.statusCode)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.25)
                .foregroundStyle(surface.foreground.opacity(0.9))
                .frame(width: 56, alignment: .leading)
            healthCopy
            if let recovery = health.recovery {
                Button("COPY FIX") {
                    onCopyCommand(recovery)
                }
                .buttonStyle(
                    NotchRowActionButtonStyle(
                        emphasis: false,
                        transitionStyle: transitionStyle,
                        palette: palette,
                        surface: surface
                    )
                )
                .frame(width: 66)
                .accessibilityLabel("Copy recovery instruction for \(health.title)")
            }
        }
        .frame(height: 31)
        .padding(.horizontal, 7)
        .background(surface.foreground.opacity(0.055))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(surface.foreground.opacity(palette.border), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(health.accessibilityLabel)
    }

    private var healthCopy: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(healthTitle)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(surface.foreground.opacity(palette.primaryText))
                .lineLimit(1)
            Text(health.message)
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(surface.foreground.opacity(palette.secondaryText))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var healthTitle: String {
        guard health.additionalCount > 0 else {
            return health.title.uppercased()
        }
        return "\(health.title.uppercased())  +\(health.additionalCount)"
    }
}

struct NotchRowActionButtonStyle: ButtonStyle {
    let emphasis: Bool
    let transitionStyle: NotchShellTransitionStyle
    let palette: NotchContrastPalette
    let surface: NotchSurfacePalette

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(0.35)
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(borderColor, lineWidth: 1)
            )
            .opacity(configuration.isPressed && transitionStyle == .opacityOnly ? 0.72 : 1)
            .scaleEffect(pressedScale(configuration: configuration))
            .animation(buttonAnimation, value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        if !isEnabled {
            return surface.foreground.opacity(palette.disabledText)
        }
        return emphasis ? surface.inverseForeground : surface.foreground
    }

    private var backgroundColor: Color {
        if !isEnabled {
            return surface.foreground.opacity(palette.disabledSurface)
        }
        return emphasis ? surface.foreground : surface.foreground.opacity(0.08)
    }

    private var borderColor: Color {
        if !isEnabled {
            return surface.foreground.opacity(palette.disabledBorder)
        }
        return emphasis
            ? surface.foreground
            : surface.foreground.opacity(palette.border)
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
