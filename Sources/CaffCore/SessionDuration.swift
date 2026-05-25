import Foundation

public struct SessionDuration: Equatable, Sendable {
    public let label: String
    public let minutes: Int?

    public init(label: String, minutes: Int?) {
        self.label = label
        self.minutes = minutes
    }

    public static let indefinitely = SessionDuration(label: "Indefinitely", minutes: nil)
    public static let thirtyMinutes = SessionDuration(label: "30 Minutes", minutes: 30)
    public static let oneHour = SessionDuration(label: "1 Hour", minutes: 60)
    public static let fourHours = SessionDuration(label: "4 Hours", minutes: 240)

    public static let presets: [SessionDuration] = [
        .indefinitely,
        .thirtyMinutes,
        .oneHour,
        .fourHours
    ]

    public var timeInterval: TimeInterval? {
        guard let minutes else {
            return nil
        }

        return TimeInterval(minutes * 60)
    }

    public func endDate(from startDate: Date) -> Date? {
        guard let timeInterval else {
            return nil
        }

        return startDate.addingTimeInterval(timeInterval)
    }
}

public enum RemainingTimeFormatter {
    public static func compactRemaining(now: Date = Date(), until endDate: Date?) -> String {
        guard let endDate else {
            return "on"
        }

        let remainingSeconds = max(0, Int(ceil(endDate.timeIntervalSince(now))))
        if remainingSeconds >= 3600 {
            let hours = remainingSeconds / 3600
            let minutes = (remainingSeconds % 3600) / 60
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }

        if remainingSeconds >= 60 {
            let minutes = Int(ceil(Double(remainingSeconds) / 60.0))
            return "\(minutes)m"
        }

        return "\(remainingSeconds)s"
    }
}
