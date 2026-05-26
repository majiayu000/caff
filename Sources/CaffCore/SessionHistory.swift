import Foundation

public enum SessionHistoryResult: String, Codable, Equatable, Sendable {
    case stopped
    case timedOut
    case policyStopped
    case error

    public var label: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .timedOut:
            return "Timed Out"
        case .policyStopped:
            return "Policy Stopped"
        case .error:
            return "Error"
        }
    }
}

public struct SessionHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let source: String
    public let reason: String
    public let durationLabel: String
    public let assertionKinds: [String]
    public let result: SessionHistoryResult
    public let errorMessage: String?

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        source: String,
        reason: String,
        durationLabel: String,
        assertionKinds: [String],
        result: SessionHistoryResult,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.reason = reason
        self.durationLabel = durationLabel
        self.assertionKinds = assertionKinds
        self.result = result
        self.errorMessage = errorMessage
    }

    public init(
        session: WakeSession,
        endedAt: Date = Date(),
        result: SessionHistoryResult,
        errorMessage: String? = nil
    ) {
        self.init(
            startedAt: session.startedAt,
            endedAt: endedAt,
            source: session.sourceLabel,
            reason: session.reason,
            durationLabel: session.duration.label,
            assertionKinds: session.activeAssertions.sorted { $0.sortOrder < $1.sortOrder }.map(\.displayName),
            result: result,
            errorMessage: errorMessage
        )
    }

    public var summary: String {
        return "\(result.label): \(source) - \(durationLabel)"
    }
}
