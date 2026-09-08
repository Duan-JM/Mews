import SwiftUI

enum NotchGlowSignal: Equatable {
    case hidden
    case running
    case attention
    case stopped
}

struct NotchGlowPresentation: Equatable {
    let signal: NotchGlowSignal
    let pulses: Bool

    var isVisible: Bool {
        return signal != .hidden
    }

    var accessibilityLabel: String {
        switch signal {
        case .hidden:
            return "Mews has no active sessions"
        case .running:
            return "Mews agents are running"
        case .attention:
            return "Mews needs input"
        case .stopped:
            return "Mews agents are stopped"
        }
    }

    static func resolved(
        snapshot: NotchShellSnapshot
    ) -> NotchGlowPresentation {
        if snapshot.stopPulseActive || snapshot.visibility == .peek {
            return NotchGlowPresentation(signal: .stopped, pulses: true)
        }

        if let statuses = snapshot.content.aggregateStatuses {
            if statuses.contains(.needsInput) {
                return NotchGlowPresentation(signal: .attention, pulses: true)
            }
            if statuses.contains(.running) {
                return NotchGlowPresentation(signal: .running, pulses: false)
            }
            return NotchGlowPresentation(
                signal: statuses.isEmpty ? .hidden : .stopped,
                pulses: false
            )
        }

        switch snapshot.presentationState.status {
        case .idle:
            return NotchGlowPresentation(signal: .hidden, pulses: false)
        case .running:
            return NotchGlowPresentation(signal: .running, pulses: false)
        case .needsInput:
            return NotchGlowPresentation(signal: .attention, pulses: true)
        case .done, .failed:
            return NotchGlowPresentation(signal: .stopped, pulses: false)
        }
    }
}

struct NotchGlowView: View {
    let shape: NotchShellShape
    let presentation: NotchGlowPresentation
    let reduceMotion: Bool
    let increaseContrast: Bool

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1 / 30,
                paused: reduceMotion || !presentation.pulses
            )
        ) { context in
            let intensity = pulseIntensity(at: context.date)
            shape
                .stroke(
                    signalColor.opacity(
                        (increaseContrast ? 1 : 0.82) * intensity
                    ),
                    lineWidth: increaseContrast ? 2 : 1.5
                )
                .shadow(
                    color: signalColor.opacity(0.9 * intensity),
                    radius: 3 + (3 * intensity)
                )
                .shadow(
                    color: signalColor.opacity(0.48 * intensity),
                    radius: 8 + (5 * intensity)
                )
        }
        .accessibilityHidden(true)
    }

    private var signalColor: Color {
        switch presentation.signal {
        case .running:
            return Color(red: 0.22, green: 1, blue: 0.46)
        case .attention, .stopped:
            return Color(red: 1, green: 0.16, blue: 0.24)
        case .hidden:
            return .clear
        }
    }

    private func pulseIntensity(at date: Date) -> Double {
        guard presentation.pulses, !reduceMotion else {
            return 1
        }
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 1)
        return 0.55 + (0.45 * ((sin(phase * 2 * .pi) + 1) / 2))
    }
}
