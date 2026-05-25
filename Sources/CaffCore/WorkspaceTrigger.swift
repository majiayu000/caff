import Foundation

public enum WorkspaceActivitySignal: Equatable, Sendable {
    case gitIndexLock
    case recentFile(relativePath: String, modifiedAt: Date)
    case marker(name: String)

    public var label: String {
        switch self {
        case .gitIndexLock:
            return ".git/index.lock"
        case let .recentFile(relativePath, _):
            return "recent file: \(relativePath)"
        case let .marker(name):
            return "marker: \(name)"
        }
    }
}

public struct WorkspaceActivity: Equatable, Sendable {
    public let path: String
    public let signal: WorkspaceActivitySignal

    public init(path: String, signal: WorkspaceActivitySignal) {
        self.path = path
        self.signal = signal
    }

    public var displayName: String {
        "\(URL(fileURLWithPath: path).lastPathComponent): \(signal.label)"
    }
}

public struct WorkspaceTriggerConfiguration: Equatable, Sendable {
    public var paths: [String]
    public var recentActivityWindowSeconds: Int
    public var gracePeriodSeconds: Int

    public init(
        paths: [String],
        recentActivityWindowSeconds: Int = 300,
        gracePeriodSeconds: Int = 60
    ) {
        self.paths = paths
        self.recentActivityWindowSeconds = recentActivityWindowSeconds
        self.gracePeriodSeconds = gracePeriodSeconds
    }

    public var normalizedPaths: [String] {
        paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

public struct WorkspaceTriggerState: Equatable, Sendable {
    public let lastActivities: [WorkspaceActivity]
    public let lastSeenAt: Date?
    public let graceUntil: Date?

    public init(
        lastActivities: [WorkspaceActivity] = [],
        lastSeenAt: Date? = nil,
        graceUntil: Date? = nil
    ) {
        self.lastActivities = lastActivities
        self.lastSeenAt = lastSeenAt
        self.graceUntil = graceUntil
    }

    public static let inactive = WorkspaceTriggerState()
}

public struct WorkspaceTriggerEvaluation: Equatable, Sendable {
    public let isKeepingAwake: Bool
    public let isInGracePeriod: Bool
    public let activities: [WorkspaceActivity]
    public let graceUntil: Date?

    public var reason: String {
        guard let firstActivity = activities.first else {
            return "Workspace trigger"
        }

        let extra = activities.count > 1 ? " +\(activities.count - 1)" : ""
        return "Workspace trigger: \(firstActivity.displayName)\(extra)"
    }

    public var summary: String {
        if !isKeepingAwake {
            return "Workspace trigger idle"
        }

        if isInGracePeriod {
            return "Workspace trigger grace: \(activities.map(\.displayName).joined(separator: ", "))"
        }

        return "Workspace trigger active: \(activities.map(\.displayName).joined(separator: ", "))"
    }
}

public struct WorkspaceTriggerEvaluator: Sendable {
    public let configuration: WorkspaceTriggerConfiguration

    public init(configuration: WorkspaceTriggerConfiguration) {
        self.configuration = configuration
    }

    public func evaluate(
        activities: [WorkspaceActivity],
        previousState: WorkspaceTriggerState,
        now: Date = Date()
    ) -> (WorkspaceTriggerEvaluation, WorkspaceTriggerState) {
        if !activities.isEmpty {
            let graceUntil = now.addingTimeInterval(TimeInterval(configuration.gracePeriodSeconds))
            let state = WorkspaceTriggerState(
                lastActivities: activities,
                lastSeenAt: now,
                graceUntil: graceUntil
            )
            let evaluation = WorkspaceTriggerEvaluation(
                isKeepingAwake: true,
                isInGracePeriod: false,
                activities: activities,
                graceUntil: graceUntil
            )
            return (evaluation, state)
        }

        if let graceUntil = previousState.graceUntil,
           graceUntil > now,
           !previousState.lastActivities.isEmpty {
            let evaluation = WorkspaceTriggerEvaluation(
                isKeepingAwake: true,
                isInGracePeriod: true,
                activities: previousState.lastActivities,
                graceUntil: graceUntil
            )
            return (evaluation, previousState)
        }

        let evaluation = WorkspaceTriggerEvaluation(
            isKeepingAwake: false,
            isInGracePeriod: false,
            activities: [],
            graceUntil: nil
        )
        return (evaluation, .inactive)
    }
}
