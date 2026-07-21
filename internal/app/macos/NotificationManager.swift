import Foundation
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private static let commandCategoryIdentifier = "dev.mews.cli-context.command"
    private static let directoryCategoryIdentifier = "dev.mews.cli-context.directory"

    private let center: UNUserNotificationCenter
    private let statusURL: URL
    private let contextOpener: CLIContextOpener
    private let onAcknowledge: (SessionIdentity, String?) -> Void
    private let log: (String) -> Void
    private var settingsTimer: Timer?

    init(
        center: UNUserNotificationCenter = .current(),
        statusURL: URL,
        contextOpener: CLIContextOpener,
        onAcknowledge: @escaping (SessionIdentity, String?) -> Void,
        log: @escaping (String) -> Void
    ) {
        self.center = center
        self.statusURL = statusURL
        self.contextOpener = contextOpener
        self.onAcknowledge = onAcknowledge
        self.log = log
    }

    deinit {
        settingsTimer?.invalidate()
    }

    func configure() {
        center.delegate = self
        center.setNotificationCategories(notificationCategories())
        startSettingsRefresh()
        readNotificationSettings()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            if let error {
                self?.log("Could not request notification permission: \(error)")
            }
            self?.readNotificationSettings()
        }
    }

    func send(for candidate: SessionAttentionCandidate) {
        log("Notification queued for attention \(candidate.notificationIdentifier)")

        let content = UNMutableNotificationContent()
        content.title = candidate.notificationTitle
        content.subtitle = candidate.notificationSubtitle
        content.body = candidate.notificationBody
        content.sound = .default
        let context = candidate.returnContext?.actionable()
        content.userInfo = candidate.notificationUserInfo
        if let context {
            content.categoryIdentifier = context.returnCommand == nil
                ? Self.directoryCategoryIdentifier
                : Self.commandCategoryIdentifier
        }

        let request = UNNotificationRequest(
            identifier: candidate.notificationIdentifier,
            content: content,
            trigger: nil
        )
        center.add(request) { [weak self] error in
            if let error {
                self?.log("Could not deliver notification: \(error)")
            }
        }
    }

    func remove(identifiers: [String]) {
        guard !identifiers.isEmpty else {
            return
        }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let context = CLIContextPayload(userInfo: response.notification.request.content.userInfo)
        let intent = CLIContextIntent.resolve(
            actionIdentifier: response.actionIdentifier,
            defaultActionIdentifier: UNNotificationDefaultActionIdentifier,
            context: context
        )
        switch intent {
        case .open:
            acknowledge(response.notification.request.content.userInfo)
            if let context {
                contextOpener.open(context)
            }
        case .copy:
            if let command = context?.returnCommand {
                contextOpener.copy(command)
            }
        case .none:
            break
        }
    }

    private func acknowledge(_ userInfo: [AnyHashable: Any]) {
        guard let source = userInfo["source"] as? String,
              let sessionID = userInfo["session_id"] as? String,
              let identity = SessionIdentity(source: source, sessionID: sessionID) else {
            log("Notification response did not contain a valid session identity")
            return
        }
        onAcknowledge(identity, userInfo["attention_id"] as? String)
    }

    private func notificationCategories() -> Set<UNNotificationCategory> {
        let openAction = UNNotificationAction(
            identifier: CLIContextIntent.openActionIdentifier,
            title: "Return to CLI",
            options: [.foreground]
        )
        let copyAction = UNNotificationAction(
            identifier: CLIContextIntent.copyActionIdentifier,
            title: "Copy Return Command",
            options: []
        )
        return [
            UNNotificationCategory(
                identifier: Self.commandCategoryIdentifier,
                actions: [openAction, copyAction],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: Self.directoryCategoryIdentifier,
                actions: [openAction],
                intentIdentifiers: [],
                options: []
            )
        ]
    }

    private func readNotificationSettings() {
        center.getNotificationSettings { [weak self] settings in
            guard let self else {
                return
            }
            log(
                "Notification settings authorization=\(settings.authorizationStatus.rawValue) " +
                    "alert=\(settings.alertSetting.rawValue) " +
                    "center=\(settings.notificationCenterSetting.rawValue)"
            )
            writeNotificationStatus(settings.authorizationStatus)
        }
    }

    private func writeNotificationStatus(_ status: UNAuthorizationStatus) {
        let value: String
        switch status {
        case .authorized, .provisional, .ephemeral:
            value = "authorized"
        case .denied:
            value = "denied"
        case .notDetermined:
            value = "not_determined"
        @unknown default:
            value = "unknown"
        }

        do {
            let data = try NotificationStatusRecord(status: value, checkedAt: Date()).encoded()
            try FileManager.default.createDirectory(
                at: statusURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: statusURL, options: .atomic)
        } catch {
            log("Could not write notification status: \(error)")
        }
    }
}
