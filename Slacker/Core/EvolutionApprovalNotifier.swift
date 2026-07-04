import Foundation
import UserNotifications

/// Local macOS notification for self-evolution proposals that require human approval.
/// Proposals are inert until approved, so this is a prompt to review, not a behavior change.
struct EvolutionApprovalNotifier {
    private static let requestIdentifier = "slacker.evolutionApproval.pending"

    func notifyPendingApproval(count: Int) async {
        guard count > 0 else {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.requestIdentifier])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.requestIdentifier])
            return
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else {
                    Log.info("Evolution approval notification skipped: notification permission denied.")
                    return
                }
            } catch {
                Log.info("Evolution approval notification skipped: authorization failed (\(error)).")
                return
            }
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            Log.info("Evolution approval notification skipped: notifications are disabled.")
            return
        @unknown default:
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Detection update needs approval"
        content.body = count == 1
            ? "Slacker proposed 1 learned detection update. Review it in Settings before it can affect detection."
            : "Slacker proposed \(count) learned detection updates. Review them in Settings before they can affect detection."
        content.sound = .default
        content.threadIdentifier = "slacker.evolutionApproval"

        let request = UNNotificationRequest(
            identifier: Self.requestIdentifier,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            Log.info("Evolution approval notification skipped: schedule failed (\(error)).")
        }
    }
}
