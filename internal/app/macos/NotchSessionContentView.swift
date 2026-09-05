import SwiftUI

struct NotchSessionContentView: View {
    let snapshot: NotchShellSnapshot
    @ObservedObject var sessionListModel: SessionListPresentationModel
    let palette: NotchContrastPalette
    let surface: NotchSurfacePalette
    let onReturnToCLI: (CLIContextPayload, SessionIdentity?) -> Void
    let onCopyCommand: (String) -> Void

    var body: some View {
        SessionListScrollContainer(
            swipeInputRouter: sessionListModel.inputRouter
        ) {
            LazyVStack(spacing: 0) {
                ForEach(sessionListModel.snapshot.rows, id: \.id) { row in
                    GeometryReader { geometry in
                        swipeRow(row, rowWidth: geometry.size.width)
                    }
                    .frame(height: sessionListModel.snapshot.visual(for: row).height)
                    .clipped()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 7)
        .accessibilityLabel("Active sessions")
    }

    private func swipeRow(
        _ row: SessionPresentationRow,
        rowWidth: CGFloat
    ) -> some View {
        let visual = sessionListModel.snapshot.visual(for: row)
        let removalToken = sessionListModel.removalToken(for: row.id)
        return ZStack(alignment: .trailing) {
            hideActionLayer(row, visual: visual, rowWidth: rowWidth)
                .zIndex(visual.usesFullWidthAction ? 2 : 0)
            sessionRow(row, visual: visual, rowWidth: rowWidth)
                .offset(x: visual.offset)
                .zIndex(1)
        }
        .opacity(visual.opacity)
        .frame(width: rowWidth, height: 42)
        .clipped()
        .modifier(
            SessionRemovalAnimationObserver(
                offset: visual.offset,
                opacity: visual.opacity,
                height: visual.height,
                targetOffset: -rowWidth,
                requiresSpatialCompletion: snapshot.transitionStyle == .spatial,
                isActive: removalToken != nil,
                onCompletion: {
                    if let removalToken {
                        sessionListModel.finishRemovalAnimation(
                            rowID: row.id,
                            token: removalToken
                        )
                    }
                }
            )
        )
        .onDisappear {
            if let removalToken {
                sessionListModel.finishRemovalAnimation(
                    rowID: row.id,
                    token: removalToken
                )
            }
        }
        .background {
            if visual.acceptsSwipeInput,
               let request = row.dismissalRequest {
                SessionSwipeRowMarker(
                    request: request,
                    inputRouter: sessionListModel.inputRouter
                )
            }
        }
    }

    private func sessionRow(
        _ row: SessionPresentationRow,
        visual: SessionSwipeRowVisual,
        rowWidth: CGFloat
    ) -> some View {
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
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                if visual.phase == .revealed || visual.phase == .failed {
                    sessionListModel.closeRevealedRow()
                }
            }
        )
        .overlay(rule, alignment: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.accessibilityLabel)
        .modifier(
            SessionHideAccessibilityModifier(
                canHide: row.dismissalRequest != nil,
                onHide: {
                    sessionListModel.requestHide(row, rowWidth: rowWidth)
                }
            )
        )
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
                sessionListModel.prepareForRowAction()
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
                sessionListModel.prepareForRowAction()
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

    private func hideActionLayer(
        _ row: SessionPresentationRow,
        visual: SessionSwipeRowVisual,
        rowWidth: CGFloat
    ) -> some View {
        let width = visual.actionWidth(rowWidth: rowWidth)
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button {
                sessionListModel.requestHide(row, rowWidth: rowWidth)
            } label: {
                Text("HIDE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(Color.white)
                    .opacity(visual.actionLabelOpacity)
                    .scaleEffect(visual.actionScale)
            }
            .buttonStyle(.plain)
            .frame(width: width, height: 42)
            .background(Color(nsColor: .systemRed))
            .opacity(visual.actionOpacity)
            .allowsHitTesting(visual.actionAcceptsInput)
            .accessibilityHidden(true)
        }
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

private struct SessionHideAccessibilityModifier: ViewModifier {
    let canHide: Bool
    let onHide: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if canHide {
            content.accessibilityAction(
                named: Text("Hide from Active Sessions")
            ) {
                onHide()
            }
        } else {
            content
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
