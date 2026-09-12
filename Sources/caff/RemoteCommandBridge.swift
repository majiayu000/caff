import CaffCore
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
        static let token = "token"
    }

    /// Attaches the per-install remote-command token when missing, then posts over DNC.
    static func post(
        _ userInfo: [String: String],
        auth: RemoteCommandAuth = RemoteCommandAuth()
    ) throws {
        var payload = userInfo
        if payload[Key.token] == nil {
            payload[Key.token] = try auth.loadOrCreateToken()
        }
        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: bundleIdentifier,
            userInfo: payload,
            deliverImmediately: true
        )
    }
}
