import Foundation

enum MewsPresentationStatus: Equatable {
    case idle
    case running
    case needsInput
    case done
    case failed
}

enum MewsPresentationPose: Equatable {
    case sleeping
    case working
    case attention
    case success
    case failure
}

enum MewsPresentationAttention: Equatable {
    case quiet
    case active
    case notice
    case urgent
}

enum MewsPresentationMotion: Equatable {
    case none
    case workingLoop
    case attentionLoop
    case completionOnce
    case failureOnce

    var repeats: Bool {
        self == .workingLoop || self == .attentionLoop
    }

    var isOneShot: Bool {
        self == .completionOnce || self == .failureOnce
    }
}

struct MewsPresentationState: Equatable {
    let status: MewsPresentationStatus
    let pose: MewsPresentationPose
    let attention: MewsPresentationAttention
    let motion: MewsPresentationMotion
    let accessibilityLabel: String
    let transitionIdentifier: String?

    init(event: MewsEvent?) {
        status = Self.presentationStatus(for: event)
        pose = Self.presentationPose(for: status)
        attention = Self.presentationAttention(for: status)
        motion = Self.presentationMotion(for: status)
        accessibilityLabel = Self.accessibilityLabel(for: status)
        transitionIdentifier = Self.transitionIdentifier(for: event, motion: motion)
    }

    func effectiveMotion(reduceMotion: Bool) -> MewsPresentationMotion {
        reduceMotion ? .none : motion
    }

    private static func presentationStatus(for event: MewsEvent?) -> MewsPresentationStatus {
        switch event?.status {
        case "running":
            return .running
        case "needs_input":
            return .needsInput
        case "done":
            return .done
        case "failed":
            return .failed
        default:
            return .idle
        }
    }

    private static func presentationPose(for status: MewsPresentationStatus) -> MewsPresentationPose {
        switch status {
        case .idle:
            return .sleeping
        case .running:
            return .working
        case .needsInput:
            return .attention
        case .done:
            return .success
        case .failed:
            return .failure
        }
    }

    private static func presentationAttention(
        for status: MewsPresentationStatus
    ) -> MewsPresentationAttention {
        switch status {
        case .idle:
            return .quiet
        case .running:
            return .active
        case .done:
            return .notice
        case .needsInput, .failed:
            return .urgent
        }
    }

    private static func presentationMotion(for status: MewsPresentationStatus) -> MewsPresentationMotion {
        switch status {
        case .idle:
            return .none
        case .running:
            return .workingLoop
        case .needsInput:
            return .attentionLoop
        case .done:
            return .completionOnce
        case .failed:
            return .failureOnce
        }
    }

    private static func accessibilityLabel(for status: MewsPresentationStatus) -> String {
        switch status {
        case .idle:
            return "Mews is idle"
        case .running:
            return "Mews agent is running"
        case .needsInput:
            return "Mews needs input"
        case .done:
            return "Mews task completed"
        case .failed:
            return "Mews task failed"
        }
    }

    private static func transitionIdentifier(
        for event: MewsEvent?,
        motion: MewsPresentationMotion
    ) -> String? {
        guard motion.isOneShot, let event else {
            return nil
        }
        if let id = normalizedText(event.id) {
            return id
        }
        let session = normalizedText(event.sessionID) ?? ""
        let timestamp = event.timestamp.timeIntervalSinceReferenceDate.bitPattern
        return "\(event.source)|\(event.status)|\(session)|\(timestamp)"
    }
}

func latestPresentationState(in events: [MewsEvent]) -> MewsPresentationState {
    return MewsPresentationState(event: latestPrimaryEvent(in: events))
}
