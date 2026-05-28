import Foundation

public enum SessionSource: String, CaseIterable, Sendable {
    case manual
    case process
    case workspace
    case agent
    case cli
    case url

    public var label: String {
        switch self {
        case .manual:
            return "Manual"
        case .process:
            return "Process"
        case .workspace:
            return "Workspace"
        case .agent:
            return "Agent"
        case .cli:
            return "CLI"
        case .url:
            return "URL"
        }
    }
}

public struct WakeSession: Equatable, Sendable {
    public let source: SessionSource
    public let duration: SessionDuration
    public let startedAt: Date
    public let endDate: Date?
    public let keepDisplayAwake: Bool
    public let reason: String
    public let activeAssertions: Set<PowerAssertionKind>
    public let errorMessage: String?

    public init(
        options: SessionOptions,
        startedAt: Date,
        activeAssertions: Set<PowerAssertionKind>,
        errorMessage: String? = nil,
        endDate: Date? = nil
    ) {
        self.source = options.source
        self.duration = options.duration
        self.startedAt = startedAt
        self.endDate = endDate ?? options.duration.endDate(from: startedAt)
        self.keepDisplayAwake = options.keepDisplayAwake
        self.reason = options.reason
        self.activeAssertions = activeAssertions
        self.errorMessage = errorMessage
    }

    public func updatingAssertions(
        _ activeAssertions: Set<PowerAssertionKind>,
        keepDisplayAwake: Bool,
        errorMessage: String? = nil
    ) -> WakeSession {
        WakeSession(
            source: source,
            duration: duration,
            startedAt: startedAt,
            endDate: endDate,
            keepDisplayAwake: keepDisplayAwake,
            reason: reason,
            activeAssertions: activeAssertions,
            errorMessage: errorMessage
        )
    }

    public func updatingSource(_ source: SessionSource, reason: String) -> WakeSession {
        WakeSession(
            source: source,
            duration: duration,
            startedAt: startedAt,
            endDate: endDate,
            keepDisplayAwake: keepDisplayAwake,
            reason: reason,
            activeAssertions: activeAssertions,
            errorMessage: errorMessage
        )
    }

    public var sourceLabel: String {
        source.label
    }

    public var assertionSummary: String {
        guard !activeAssertions.isEmpty else {
            return "None"
        }

        return activeAssertions
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.displayName)
            .joined(separator: ", ")
    }

    public func compactStatus(now: Date = Date()) -> String {
        if errorMessage != nil {
            return "error"
        }

        return RemainingTimeFormatter.compactRemaining(now: now, until: endDate)
    }

    private init(
        source: SessionSource,
        duration: SessionDuration,
        startedAt: Date,
        endDate: Date?,
        keepDisplayAwake: Bool,
        reason: String,
        activeAssertions: Set<PowerAssertionKind>,
        errorMessage: String?
    ) {
        self.source = source
        self.duration = duration
        self.startedAt = startedAt
        self.endDate = endDate
        self.keepDisplayAwake = keepDisplayAwake
        self.reason = reason
        self.activeAssertions = activeAssertions
        self.errorMessage = errorMessage
    }
}
