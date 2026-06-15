import Foundation
@preconcurrency import UserNotifications

enum LocalNotifier {
    static func notify(title: String, body: String) {
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
                trigger: nil
            )
            center.add(request) { error in
                if let error {
                    Audit.record(kind: "tool.local_notifications", summary: "系统通知发送失败",
                                 detail: ["error": error.localizedDescription])
                } else {
                    Audit.record(kind: "tool.local_notifications", summary: "已发送系统通知")
                }
            }
        }
    }
}
