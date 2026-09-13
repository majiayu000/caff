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
        static let token = RemoteCommandAuth.PayloadKey.token
        static let ticket = RemoteCommandAuth.PayloadKey.ticket
        static let mac = RemoteCommandAuth.PayloadKey.mac
        static let nonce = RemoteCommandAuth.PayloadKey.nonce
        static let timestamp = RemoteCommandAuth.PayloadKey.timestamp
    }

    /// Signs the payload with a short-lived HMAC and posts over DNC without broadcasting the reusable token.
    static func post(
        _ userInfo: [String: String],
        auth: RemoteCommandAuth = RemoteCommandAuth()
    ) throws {
        let payload = try auth.sign(userInfo)
        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: bundleIdentifier,
            userInfo: payload,
            deliverImmediately: true
        )
    }
}
