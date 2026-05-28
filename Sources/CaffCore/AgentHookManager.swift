import Foundation

public enum AgentHookTarget: String, CaseIterable, Sendable {
    case codex
    case claude

    public var label: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        }
    }

    var sourceName: String { rawValue }

    var relativeConfigPath: String {
        switch self {
        case .codex:
            return ".codex/hooks.json"
        case .claude:
            return ".claude/settings.json"
        }
    }

    var eventNames: [String] {
        switch self {
        case .codex:
            return ["UserPromptSubmit", "SessionStart", "PreToolUse", "PostToolUse", "Stop"]
        case .claude:
            return ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"]
        }
    }

    var needsMatcher: Bool { self == .claude }
}

public struct AgentHookChange: Equatable, Sendable {
    public let target: AgentHookTarget
    public let configPath: String
    public let changed: Bool
    public let hookCount: Int

    public var summary: String {
        let action = changed ? "updated" : "already current"
        return "\(target.label) hooks \(action): \(configPath)"
    }
}

public enum AgentHookManagerError: Error, CustomStringConvertible, Equatable {
    case invalidJSON(String)
    case unsupportedRoot(String)

    public var description: String {
        switch self {
        case let .invalidJSON(path):
            return "Invalid JSON: \(path)"
        case let .unsupportedRoot(path):
            return "Hook config root must be a JSON object: \(path)"
        }
    }
}

public struct AgentHookManager {
    private let homeDirectory: URL
    private let executablePath: String
    private let cooldownSeconds: Int

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        executablePath: String,
        cooldownSeconds: Int = AgentActivityCooldown.defaultCooldownSeconds
    ) {
        self.homeDirectory = homeDirectory
        self.executablePath = executablePath
        self.cooldownSeconds = cooldownSeconds
    }

    public func install(targets: [AgentHookTarget] = AgentHookTarget.allCases) throws -> [AgentHookChange] {
        try targets.map { try update(target: $0, operation: .install) }
    }

    public func remove(targets: [AgentHookTarget] = AgentHookTarget.allCases) throws -> [AgentHookChange] {
        try targets.map { try update(target: $0, operation: .remove) }
    }

    public func configURL(for target: AgentHookTarget) -> URL {
        homeDirectory.appendingPathComponent(target.relativeConfigPath)
    }

    private func update(target: AgentHookTarget, operation: Operation) throws -> AgentHookChange {
        let url = configURL(for: target)
        var root = try readConfig(at: url)
        let before = normalizedJSON(root)

        switch operation {
        case .install:
            root = removeCaffHooks(from: root, target: target)
            root = addCaffHooks(to: root, target: target)
        case .remove:
            root = removeCaffHooks(from: root, target: target)
        }

        let after = normalizedJSON(root)
        let changed = before != after
        if changed {
            try writeConfig(root, to: url)
        }

        return AgentHookChange(
            target: target,
            configPath: url.path,
            changed: changed,
            hookCount: target.eventNames.count
        )
    }

    private func readConfig(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return [:]
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AgentHookManagerError.invalidJSON(url.path)
        }
        guard let root = value as? [String: Any] else {
            throw AgentHookManagerError.unsupportedRoot(url.path)
        }
        return root
    }

    private func writeConfig(_ root: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
    }

    private func addCaffHooks(to root: [String: Any], target: AgentHookTarget) -> [String: Any] {
        var root = root
        var hooksByEvent = root["hooks"] as? [String: Any] ?? [:]

        for eventName in target.eventNames {
            var entries = hooksByEvent[eventName] as? [[String: Any]] ?? []
            var wrapper = ["hooks": [hookCommand(target: target)] as [[String: Any]]] as [String: Any]
            if target.needsMatcher {
                wrapper["matcher"] = "*"
            }
            entries.append(wrapper)
            hooksByEvent[eventName] = entries
        }

        root["hooks"] = hooksByEvent
        return root
    }

    private func removeCaffHooks(from root: [String: Any], target: AgentHookTarget) -> [String: Any] {
        var root = root
        guard var hooksByEvent = root["hooks"] as? [String: Any] else {
            return root
        }

        for eventName in target.eventNames {
            guard let entries = hooksByEvent[eventName] as? [[String: Any]] else {
                continue
            }
            let cleanedEntries = entries.compactMap { entry -> [String: Any]? in
                var entry = entry
                guard let hooks = entry["hooks"] as? [[String: Any]] else {
                    return entry
                }
                let cleanedHooks = hooks.filter { hook in
                    guard let command = hook["command"] as? String else {
                        return true
                    }
                    return !isCaffHookCommand(command, target: target)
                }
                if cleanedHooks.isEmpty {
                    return nil
                }
                entry["hooks"] = cleanedHooks
                return entry
            }
            hooksByEvent[eventName] = cleanedEntries
        }

        root["hooks"] = hooksByEvent
        return root
    }

    private func hookCommand(target: AgentHookTarget) -> [String: Any] {
        [
            "command": "\(shellEscaped(executablePath)) agent-touch --source \(target.sourceName) --cooldown-seconds \(cooldownSeconds) >/dev/null 2>&1",
            "timeout": 10,
            "type": "command"
        ]
    }

    private func isCaffHookCommand(_ command: String, target: AgentHookTarget) -> Bool {
        command.contains("agent-touch")
            && command.contains("--source \(target.sourceName)")
    }

    private func shellEscaped(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func normalizedJSON(_ root: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "\(root)"
        }
        return string
    }

    private enum Operation {
        case install
        case remove
    }
}
