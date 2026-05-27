import Foundation

public struct AgentActivityState: Equatable, Sendable {
    public let source: String
    public let lastActivityAt: Date
    public let cooldownSeconds: Int

    public init(source: String, lastActivityAt: Date, cooldownSeconds: Int = AgentActivityCooldown.defaultCooldownSeconds) {
        self.source = AgentActivityCooldown.normalizedSource(source)
        self.lastActivityAt = lastActivityAt
        self.cooldownSeconds = cooldownSeconds
    }
}

public struct AgentActivityEvaluation: Equatable, Sendable {
    public let isKeepingAwake: Bool
    public let source: String?
    public let lastActivityAt: Date?
    public let cooldownUntil: Date?
    public let remainingSeconds: Int

    public var reason: String {
        guard let source else {
            return "Agent activity"
        }

        return "Agent activity: \(source)"
    }

    public var summary: String {
        guard isKeepingAwake, let source else {
            return "Agent activity idle"
        }

        return "Agent activity: \(source), sleep allowed in \(RemainingTimeFormatter.compactRemaining(untilSeconds: remainingSeconds))"
    }
}

public enum AgentActivityCooldown {
    public static let defaultCooldownSeconds = 1_800

    public static func policyDurationMinutes(cooldownSeconds: Int) -> Int {
        max(1, cooldownSeconds / 60)
    }

    public static func cappedCooldownEndDate(
        lastActivityAt: Date,
        cooldownUntil: Date,
        maximumSessionMinutes: Int
    ) -> Date {
        min(
            cooldownUntil,
            lastActivityAt.addingTimeInterval(TimeInterval(maximumSessionMinutes * 60))
        )
    }

    public static func touch(
        source: String?,
        cooldownSeconds: Int = defaultCooldownSeconds,
        now: Date = Date()
    ) -> AgentActivityState {
        AgentActivityState(
            source: normalizedSource(source ?? "agent"),
            lastActivityAt: now,
            cooldownSeconds: cooldownSeconds
        )
    }

    public static func evaluate(state: AgentActivityState?, now: Date = Date()) -> AgentActivityEvaluation {
        guard let state else {
            return AgentActivityEvaluation(
                isKeepingAwake: false,
                source: nil,
                lastActivityAt: nil,
                cooldownUntil: nil,
                remainingSeconds: 0
            )
        }

        let cooldownUntil = state.lastActivityAt.addingTimeInterval(TimeInterval(state.cooldownSeconds))
        let remainingSeconds = max(0, Int(ceil(cooldownUntil.timeIntervalSince(now))))
        return AgentActivityEvaluation(
            isKeepingAwake: remainingSeconds > 0,
            source: remainingSeconds > 0 ? state.source : nil,
            lastActivityAt: state.lastActivityAt,
            cooldownUntil: cooldownUntil,
            remainingSeconds: remainingSeconds
        )
    }

    static func normalizedSource(_ source: String) -> String {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "agent" : value
    }
}
