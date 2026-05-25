import Foundation

public enum AgentCommandParseError: Error, CustomStringConvertible, Equatable, Sendable {
    case emptyExecutable
    case invalidEnvironmentAssignment(String)
    case unterminatedQuote

    public var description: String {
        switch self {
        case .emptyExecutable:
            return "Agent command executable is required"
        case let .invalidEnvironmentAssignment(assignment):
            return "Invalid environment assignment: \(assignment)"
        case .unterminatedQuote:
            return "Command arguments contain an unterminated quote"
        }
    }
}

public struct AgentCommandDefinition: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String
    public var environment: [String: String]

    public init(
        id: String,
        name: String,
        executable: String,
        arguments: [String] = [],
        workingDirectory: String = "~",
        environment: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    public var displayCommand: String {
        ([executable] + arguments).joined(separator: " ")
    }

    public static let builtInExamples: [AgentCommandDefinition] = [
        AgentCommandDefinition(id: "codex", name: "codex", executable: "codex"),
        AgentCommandDefinition(id: "claude", name: "claude", executable: "claude"),
        AgentCommandDefinition(id: "npm-test", name: "npm test", executable: "npm", arguments: ["test"]),
        AgentCommandDefinition(id: "cargo-test", name: "cargo test", executable: "cargo", arguments: ["test"])
    ]
}

public enum AgentCommandParser {
    public static func tokenizeArguments(_ input: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false

        for character in input {
            if isEscaping {
                current.append(character)
                isEscaping = false
                continue
            }

            if character == "\\" {
                isEscaping = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }

        if isEscaping {
            current.append("\\")
        }
        guard quote == nil else {
            throw AgentCommandParseError.unterminatedQuote
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    public static func parseEnvironment(_ input: String) throws -> [String: String] {
        var environment: [String: String] = [:]
        let assignments = input
            .split { $0 == "\n" || $0 == "," }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for assignment in assignments {
            guard let separator = assignment.firstIndex(of: "=") else {
                throw AgentCommandParseError.invalidEnvironmentAssignment(assignment)
            }
            let key = assignment[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw AgentCommandParseError.invalidEnvironmentAssignment(assignment)
            }
            let value = assignment[assignment.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            environment[key] = value
        }

        return environment
    }
}
