import Foundation

public struct ProcessCandidate: Equatable, Sendable {
    public let pid: Int32
    public let processName: String
    public let bundleIdentifier: String?
    public let commandLine: String

    public init(
        pid: Int32,
        processName: String,
        bundleIdentifier: String? = nil,
        commandLine: String = ""
    ) {
        self.pid = pid
        self.processName = processName
        self.bundleIdentifier = bundleIdentifier
        self.commandLine = commandLine
    }
}

public struct ProcessTriggerConfiguration: Equatable, Sendable {
    public var identifiers: [String]
    public var gracePeriodSeconds: Int

    public init(identifiers: [String], gracePeriodSeconds: Int = 60) {
        self.identifiers = identifiers
        self.gracePeriodSeconds = gracePeriodSeconds
    }

    public static let agentDefaults = ProcessTriggerConfiguration(
        identifiers: ["codex", "claude", "node", "python", "cargo", "swift"]
    )

    public var normalizedIdentifiers: [String] {
        identifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}

public struct ProcessTriggerMatch: Equatable, Sendable {
    public let identifier: String
    public let candidate: ProcessCandidate

    public init(identifier: String, candidate: ProcessCandidate) {
        self.identifier = identifier
        self.candidate = candidate
    }

    public var displayName: String {
        "\(candidate.processName) pid \(candidate.pid)"
    }
}

public struct ProcessTriggerState: Equatable, Sendable {
    public let lastMatches: [ProcessTriggerMatch]
    public let lastSeenAt: Date?
    public let graceUntil: Date?

    public init(
        lastMatches: [ProcessTriggerMatch] = [],
        lastSeenAt: Date? = nil,
        graceUntil: Date? = nil
    ) {
        self.lastMatches = lastMatches
        self.lastSeenAt = lastSeenAt
        self.graceUntil = graceUntil
    }

    public static let inactive = ProcessTriggerState()
}

public struct ProcessTriggerEvaluation: Equatable, Sendable {
    public let isKeepingAwake: Bool
    public let isInGracePeriod: Bool
    public let matches: [ProcessTriggerMatch]
    public let graceUntil: Date?

    public var reason: String {
        guard let firstMatch = matches.first else {
            return "Process trigger"
        }

        let extra = matches.count > 1 ? " +\(matches.count - 1)" : ""
        return "Process trigger: \(firstMatch.displayName)\(extra)"
    }

    public var summary: String {
        if !isKeepingAwake {
            return "Process trigger idle"
        }

        if isInGracePeriod {
            return "Process trigger grace: \(matches.map(\.displayName).joined(separator: ", "))"
        }

        return "Process trigger active: \(matches.map(\.displayName).joined(separator: ", "))"
    }
}

public struct ProcessTriggerEvaluator: Sendable {
    public let configuration: ProcessTriggerConfiguration

    public init(configuration: ProcessTriggerConfiguration = .agentDefaults) {
        self.configuration = configuration
    }

    public func evaluate(
        candidates: [ProcessCandidate],
        previousState: ProcessTriggerState,
        now: Date = Date()
    ) -> (ProcessTriggerEvaluation, ProcessTriggerState) {
        let matches = match(candidates: candidates)

        if !matches.isEmpty {
            let graceUntil = now.addingTimeInterval(TimeInterval(configuration.gracePeriodSeconds))
            let state = ProcessTriggerState(lastMatches: matches, lastSeenAt: now, graceUntil: graceUntil)
            let evaluation = ProcessTriggerEvaluation(
                isKeepingAwake: true,
                isInGracePeriod: false,
                matches: matches,
                graceUntil: graceUntil
            )
            return (evaluation, state)
        }

        if let graceUntil = previousState.graceUntil,
           graceUntil > now,
           !previousState.lastMatches.isEmpty {
            let evaluation = ProcessTriggerEvaluation(
                isKeepingAwake: true,
                isInGracePeriod: true,
                matches: previousState.lastMatches,
                graceUntil: graceUntil
            )
            return (evaluation, previousState)
        }

        let evaluation = ProcessTriggerEvaluation(
            isKeepingAwake: false,
            isInGracePeriod: false,
            matches: [],
            graceUntil: nil
        )
        return (evaluation, .inactive)
    }

    public func match(candidates: [ProcessCandidate]) -> [ProcessTriggerMatch] {
        let identifiers = configuration.normalizedIdentifiers

        return candidates.compactMap { candidate in
            guard let identifier = identifiers.first(where: { matches(candidate, identifier: $0) }) else {
                return nil
            }

            return ProcessTriggerMatch(identifier: identifier, candidate: candidate)
        }
    }

    private func matches(_ candidate: ProcessCandidate, identifier: String) -> Bool {
        let processName = candidate.processName.lowercased()

        if processName == identifier || hasAcceptedSuffix(processName, after: identifier) {
            return true
        }

        if let bundleIdentifier = candidate.bundleIdentifier?.lowercased(),
           bundleIdentifier == identifier {
            return true
        }

        return commandTokens(from: candidate.commandLine).contains(identifier)
    }

    private func hasAcceptedSuffix(_ value: String, after prefix: String) -> Bool {
        guard value.hasPrefix(prefix), value.count > prefix.count else {
            return false
        }

        let suffix = value.dropFirst(prefix.count)
        guard let first = suffix.first else {
            return false
        }

        return first == "." || first == "-" || first.isNumber
    }

    private func commandTokens(from commandLine: String) -> Set<String> {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\"'"))

        let tokens = commandLine
            .components(separatedBy: separators)
            .map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }
            .filter { !$0.isEmpty }

        return Set(tokens)
    }
}
