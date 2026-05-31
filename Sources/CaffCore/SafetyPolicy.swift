import Foundation
import IOKit.ps

public enum PowerSourceState: Equatable, Sendable {
    case acPower
    case batteryPower
    case unknown

    public var label: String {
        switch self {
        case .acPower:
            return "AC Power"
        case .batteryPower:
            return "Battery"
        case .unknown:
            return "Unknown"
        }
    }
}

public enum SafetyPolicyError: Error, CustomStringConvertible, Equatable {
    case longSessionOnBattery(durationLabel: String, thresholdMinutes: Int)

    public var description: String {
        switch self {
        case let .longSessionOnBattery(durationLabel, thresholdMinutes):
            return "\(durationLabel) sessions require AC power; battery sessions are limited below \(thresholdMinutes) minutes"
        }
    }
}

public struct SafetyPolicy: Equatable, Sendable {
    public var maximumSessionMinutes: Int
    public var longSessionBatteryThresholdMinutes: Int
    public var allowLongSessionsOnBattery: Bool

    public init(
        maximumSessionMinutes: Int = 240,
        longSessionBatteryThresholdMinutes: Int = 60,
        allowLongSessionsOnBattery: Bool = false
    ) {
        self.maximumSessionMinutes = maximumSessionMinutes
        self.longSessionBatteryThresholdMinutes = longSessionBatteryThresholdMinutes
        self.allowLongSessionsOnBattery = allowLongSessionsOnBattery
    }

    public static let standard = SafetyPolicy()

    public var summary: String {
        "Max \(Self.formatMinutes(maximumSessionMinutes)), long battery \(allowLongSessionsOnBattery ? "allowed" : "blocked")"
    }

    public func validate(duration: SessionDuration, powerSource: PowerSourceState) throws {
        if powerSource == .batteryPower,
           !allowLongSessionsOnBattery,
           isLongBatterySession(duration) {
            throw SafetyPolicyError.longSessionOnBattery(
                durationLabel: duration.label,
                thresholdMinutes: longSessionBatteryThresholdMinutes
            )
        }
    }

    public func effectiveEndDate(for duration: SessionDuration, startedAt: Date) -> Date? {
        let maximumEndDate = startedAt.addingTimeInterval(TimeInterval(maximumSessionMinutes * 60))

        guard let requestedEndDate = duration.endDate(from: startedAt) else {
            return maximumEndDate
        }

        return min(requestedEndDate, maximumEndDate)
    }

    public func sessionNotes(for duration: SessionDuration, powerSource: PowerSourceState) -> [String] {
        var notes = ["Max: \(Self.formatMinutes(maximumSessionMinutes))"]
        notes.append("Power: \(powerSource.label)")

        if duration.minutes == nil {
            notes.append("Indefinite is capped")
        } else if let minutes = duration.minutes, minutes > maximumSessionMinutes {
            notes.append("Duration is capped")
        }

        if powerSource == .batteryPower, isLongBatterySession(duration) {
            notes.append(allowLongSessionsOnBattery ? "Long battery allowed" : "Long battery blocked")
        }

        return notes
    }

    public static func formatMinutes(_ minutes: Int) -> String {
        if minutes >= 60, minutes % 60 == 0 {
            return "\(minutes / 60)h"
        }

        return "\(minutes)m"
    }

    private func isLongBatterySession(_ duration: SessionDuration) -> Bool {
        guard let minutes = duration.minutes else {
            return true
        }

        return minutes >= longSessionBatteryThresholdMinutes
    }
}

public enum PowerSourceMonitor {
    public static func current() -> PowerSourceState {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [AnyObject]

        guard !sources.isEmpty else {
            return .acPower
        }

        var sawBatterySource = false

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey as String] as? String else {
                continue
            }

            sawBatterySource = true

            if state == kIOPSACPowerValue {
                return .acPower
            }

            if state == kIOPSBatteryPowerValue {
                return .batteryPower
            }
        }

        return sawBatterySource ? .unknown : .acPower
    }
}
