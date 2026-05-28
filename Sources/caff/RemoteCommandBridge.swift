import Foundation

enum RemoteCommandBridge {
    static let bundleIdentifier = "local.caff"
    static let notificationName = Notification.Name("local.caff.remote-command")

    enum Key {
        static let action = "action"
        static let minutes = "minutes"
        static let reason = "reason"
        static let displayAwake = "displayAwake"
        static let source = "source"
        static let agentSource = "agentSource"
        static let cooldownSeconds = "cooldownSeconds"
    }

    static func post(_ userInfo: [String: String]) {
        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: bundleIdentifier,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }
}
