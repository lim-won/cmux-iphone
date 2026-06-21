import Foundation
import UserNotifications

/// Converts bridge events into local notifications.
/// Posts approval-needed and task-complete notifications when the app
/// is backgrounded, so the user is aware of events requiring attention.
final class NotificationService {

    // MARK: - Notification identifiers

    private static let approvalCategory = "APPROVAL_REQUEST"
    private static let approveAction = "APPROVE_ACTION"
    private static let denyAction = "DENY_ACTION"
    private static let taskCompleteCategory = "TASK_COMPLETE"

    // MARK: - Init

    init() {
        requestAuthorization()
        registerCategories()
    }

    // MARK: - Authorization

    private func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("[NotificationService] Authorization error: \(error)")
            }
            if !granted {
                print("[NotificationService] Notification permission not granted")
            }
        }
    }

    private func registerCategories() {
        // NOTE: Approve/Deny notification ACTION BUTTONS are intentionally omitted.
        // They require a UNUserNotificationCenterDelegate (and a permissionId in
        // userInfo) to actually answer the bridge — neither is wired up yet, so
        // advertising them would let a tap silently no-op. Until that's built,
        // the notification just opens the app, where the in-app approval queue
        // (RelayService.respond) handles it correctly. See P0-5.
        let approvalCategory = UNNotificationCategory(
            identifier: Self.approvalCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        let taskCategory = UNNotificationCategory(
            identifier: Self.taskCompleteCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            approvalCategory,
            taskCategory,
        ])
    }

    // MARK: - Posting notifications

    /// Posts a notification that an approval is needed for a tool invocation.
    func postApprovalNeeded(toolName: String, summary: String) {
        let content = UNMutableNotificationContent()
        content.title = "Approval Needed"
        content.body = "\(toolName): \(summary)"
        content.sound = .default
        content.categoryIdentifier = Self.approvalCategory
        content.userInfo = ["toolName": toolName, "summary": summary]

        let request = UNNotificationRequest(
            identifier: "approval-\(UUID().uuidString)",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[NotificationService] Failed to post approval notification: \(error)")
            }
        }
    }

    /// Posts a notification that the current task has completed.
    func postTaskComplete() {
        let content = UNMutableNotificationContent()
        content.title = "Task Complete"
        content.body = "Claude has finished the current task."
        content.sound = .default
        content.categoryIdentifier = Self.taskCompleteCategory

        let request = UNNotificationRequest(
            identifier: "task-complete-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[NotificationService] Failed to post task-complete notification: \(error)")
            }
        }
    }

    /// Removes all delivered notifications.
    func clearAll() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
