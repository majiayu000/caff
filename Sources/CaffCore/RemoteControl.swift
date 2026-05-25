import Foundation

public enum RemoteControlError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidDuration(String)
    case invalidCooldownSeconds(String)
    case invalidSource(String)

    public var description: String {
        switch self {
        case let .invalidDuration(value):
            return "Invalid duration: \(value)"
        case let .invalidCooldownSeconds(value):
            return "Invalid cooldown seconds: \(value)"
        case let .invalidSource(value):
            return "Invalid source: \(value)"
        }
    }
}

public enum RemoteControlParser {
    public static func duration(minutes: String?) throws -> SessionDuration {
        guard let minutes, !minutes.isEmpty else {
            return .indefinitely
        }
        guard let value = Int(minutes), value > 0 else {
            throw RemoteControlError.invalidDuration(minutes)
        }
        return SessionDuration(label: "\(value) Minutes", minutes: value)
    }

    public static func source(_ value: String?) throws -> SessionSource {
        guard let value, !value.isEmpty else {
            return .cli
        }
        guard let source = SessionSource(rawValue: value) else {
            throw RemoteControlError.invalidSource(value)
        }
        return source
    }

    public static func cooldownSeconds(_ value: String?) throws -> Int {
        guard let value, !value.isEmpty else {
            return AgentActivityCooldown.defaultCooldownSeconds
        }
        guard let seconds = Int(value), seconds > 0 else {
            throw RemoteControlError.invalidCooldownSeconds(value)
        }
        return seconds
    }

    public static func bool(_ value: String?) -> Bool {
        guard let value else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }
}
