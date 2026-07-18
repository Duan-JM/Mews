import Foundation
import UserNotifications

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private static let commandCategoryIdentifier = "dev.mews.cli-context.command"
    private static let directoryCategoryIdentifier = "dev.mews.cli-context.directory"

    private let center: UNUserNotificationCenter
    private let statusURL: URL
    private let contextOpener: CLIContextOpener
    private let log: (String) -> Void

    init(
        center: UNUserNotificationCenter = .current(),
        statusURL: URL,
        contextOpener: CLIContextOpener,
        log: @escaping (String) -> Void
    ) {
        self.center = center
        self.statusURL = statusURL
        self.contextOpener = contextOpener
        self.log = log
    }

    func configure() {
        center.delegate = self
        center.setNotificationCategories(notificationCategories())
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            if let error {
                self?.log("Could not request notification permission: \(error)")
            }
            self?.readNotificationSettings()
        }
    }

    func send(for event: MewsEvent) {
        guard event.shouldNotify else {
            return
        }
        log("Notification queued for event \(event.id ?? "unknown")")

        let content = UNMutableNotificationContent()
        content.title = event.notificationTitle
        content.subtitle = event.notificationSubtitle
        content.body = event.notificationBody
        content.sound = .default
        let context = event.cliContext?.actionable()
        content.userInfo = event.notificationUserInfo(including: context)
        if let context {
            content.categoryIdentifier = context.returnCommand == nil
                ? Self.directoryCategoryIdentifier
                : Self.commandCategoryIdentifier
        }

        let request = UNNotificationRequest(
            identifier: event.id ?? UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { [weak self] error in
            if let error {
                self?.log("Could not deliver notification: \(error)")
            }
        }
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

    private func notificationCategories() -> Set<UNNotificationCategory> {
        let openAction = UNNotificationAction(
            identifier: CLIContextIntent.openActionIdentifier,
            title: "Open CLI Context",
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
            let data = try JSONSerialization.data(
                withJSONObject: ["status": value],
                options: [.prettyPrinted, .sortedKeys]
            )
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
