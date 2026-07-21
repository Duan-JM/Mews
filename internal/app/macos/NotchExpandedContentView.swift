import SwiftUI

struct NotchExpandedContentView: View {
    let snapshot: NotchShellSnapshot
    let onReturnToCLI: (CLIContextPayload, SessionIdentity?) -> Void
    let onCopyCommand: (String) -> Void

    private var palette: NotchContrastPalette {
        return .resolved(increaseContrast: snapshot.increaseContrast)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let health = snapshot.content.health {
                NotchHealthRowView(
                    health: health,
                    transitionStyle: snapshot.transitionStyle,
                    palette: palette,
                    onCopyCommand: onCopyCommand
                )
                    .padding(.top, 5)
            }
            if snapshot.content.visibleSessionRows.isEmpty {
                legacyContent
            } else {
                NotchSessionContentView(
                    snapshot: snapshot,
                    palette: palette,
                    onReturnToCLI: onReturnToCLI,
                    onCopyCommand: onCopyCommand
                )
            }
        }
        .padding(.horizontal, 18)
        .foregroundStyle(Color.white)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            PixelStatusView(state: snapshot.presentationState, size: 28)
            Spacer()
            Text(topBarLabel)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(Color.white.opacity(palette.badgeText))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white.opacity(palette.border), lineWidth: 1)
                )
        }
        .frame(height: 28)
        .padding(.top, 14)
    }

    private var legacyContent: some View {
        VStack(spacing: 0) {
            currentSummary
            rule
                .padding(.top, 9)
            recentEvents
                .padding(.top, 7)
            Spacer(minLength: 6)
            legacyActions
                .padding(.bottom, 14)
        }
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
            if legacyRecent.isEmpty {
                HStack {
                    Text("NO EARLIER PRIMARY EVENTS")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(Color.white.opacity(palette.mutedText))
                    Spacer()
                }
                .frame(height: 16)
            } else {
                ForEach(
                    Array(legacyRecent.enumerated()),
                    id: \.offset
                ) { _, event in
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

    private var legacyActions: some View {
        HStack(spacing: 8) {
            Button("RETURN TO CLI") {
                if let context = snapshot.content.actionableContext {
                    onReturnToCLI(context, snapshot.content.actionableIdentity)
                }
            }
            .buttonStyle(
                NotchRowActionButtonStyle(
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
                NotchRowActionButtonStyle(
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

    private var legacyRecent: [NotchEventSummary] {
        guard snapshot.content.health != nil else {
            return snapshot.content.visibleRecent
        }
        return Array(snapshot.content.visibleRecent.prefix(1))
    }

    private var currentStatusLabel: String {
        return snapshot.content.current?.statusLabel ??
            snapshot.presentationState.status.panelLabel
    }

    private var topBarLabel: String {
        let count = snapshot.content.visibleSessionRows.count
        guard count > 0 else {
            return currentStatusLabel.uppercased()
        }
        let total = snapshot.content.sessionRows.count
        if total > count {
            return "\(count) OF \(total) SESSIONS"
        }
        return count == 1 ? "1 SESSION" : "\(count) SESSIONS"
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
