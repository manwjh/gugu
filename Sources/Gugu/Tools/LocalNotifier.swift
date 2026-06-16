import Foundation
@preconcurrency import UserNotifications

enum LocalNotifier {
    static func notify(title: String, body: String) {
        deliver(title: title, body: body, trigger: nil, scheduledFor: nil)
    }

    /// Schedule a notification to fire at a specific future date.
    static func schedule(title: String, body: String, at date: Date) {
        guard date > Date() else {
            // already past — fire now rather than silently dropping it
            deliver(title: title, body: body, trigger: nil, scheduledFor: nil)
            return
        }
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        deliver(title: title, body: body, trigger: trigger, scheduledFor: date)
    }

    private static func deliver(title: String, body: String,
                                trigger: UNNotificationTrigger?, scheduledFor: Date?) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Audit.record(kind: "tool.local_notifications", summary: "系统通知授权失败",
                             detail: ["error": error.localizedDescription])
                return
            }
            guard granted else {
                Audit.record(kind: "tool.local_notifications", summary: "系统通知未授权")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "gugu-\(UUID().uuidString)",
                content: content,
                trigger: trigger
            )
            center.add(request) { error in
                if let error {
                    Audit.record(kind: "tool.local_notifications", summary: "系统通知发送失败",
                                 detail: ["error": error.localizedDescription])
                } else {
                    var detail: [String: String] = [:]
                    if let scheduledFor {
                        detail["scheduled_for"] = ISO8601DateFormatter().string(from: scheduledFor)
                    }
                    Audit.record(kind: "tool.local_notifications",
                                 summary: scheduledFor == nil ? "已发送系统通知" : "已排定定时通知",
                                 detail: detail)
                }
            }
        }
    }
}
