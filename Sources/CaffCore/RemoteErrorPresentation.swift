import Foundation

/// Decides whether a remote/IPC failure should emit a user-visible notification.
/// Status/menu updates and stderr logging happen on every failure; notifications are rate-limited
/// so spam over DistributedNotificationCenter or `caff://` URLs cannot flood the user.
public struct RemoteErrorPresentation: Equatable, Sendable {
    public static let defaultMinimumInterval: TimeInterval = 5

    public var lastNotificationAt: Date?
    public let minimumInterval: TimeInterval

    public init(
        minimumInterval: TimeInterval = defaultMinimumInterval,
        lastNotificationAt: Date? = nil
    ) {
        self.minimumInterval = minimumInterval
        self.lastNotificationAt = lastNotificationAt
    }

    /// Returns `true` when a non-blocking UserNotification should be delivered for this failure.
    public mutating func shouldEmitNotification(now: Date = Date()) -> Bool {
        if let lastNotificationAt, now.timeIntervalSince(lastNotificationAt) < minimumInterval {
            return false
        }
        lastNotificationAt = now
        return true
    }
}
