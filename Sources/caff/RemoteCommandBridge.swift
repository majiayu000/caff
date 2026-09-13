import CaffCore
import Foundation

enum RemoteCommandBridge {
    static let bundleIdentifier = "local.caff"
    static let notificationName = Notification.Name("local.caff.remote-command")
    /// Posted after a trusted CLI provision (authorize-remote / install-hooks) so a
    /// live app that cancelled launch-time attestation can register receivers.
    static let retryProvisionNotificationName = Notification.Name("local.caff.remote-control.retry-provision")

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

    /// Asks a running app to retry remote-control handler registration after a
    /// trusted lease was written. Safe to post when no app is listening.
    static func postRetryProvision() {
        DistributedNotificationCenter.default().postNotificationName(
            retryProvisionNotificationName,
            object: bundleIdentifier,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Signs the payload with a short-lived HMAC and posts over DNC without broadcasting the reusable token.
    static func post(
        _ userInfo: [String: String],
        auth: RemoteCommandAuth = RemoteCommandAuth()
    ) throws {
        let payload = try auth.sign(userInfo)
        // sign() may remint under a validated lease; rebind that lease to the new secret
        // so the next fresh CLI process can authenticate without re-prompting.
        RemoteCommandUserAuthorization.recordProvisioningLeaseIfNeeded()
        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: bundleIdentifier,
            userInfo: payload,
            deliverImmediately: true
        )
    }
}
