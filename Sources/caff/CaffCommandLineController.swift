import AppKit
import CaffCore
import Darwin
import Foundation

enum CaffCommandLineError: Error, CustomStringConvertible {
    case missingCommand
    case missingValue(String)
    case unknownCommand(String)
    case unknownOption(String)
    case cannotStartApp
    case statusUnavailable
    case invalidHookTarget(String)

    var description: String {
        switch self {
        case .missingCommand:
            return "Missing command. Use: caff start|stop|status|agent-touch|install-hooks|remove-hooks"
        case let .missingValue(option):
            return "Missing value for \(option)"
        case let .unknownCommand(command):
            return "Unknown command: \(command)"
        case let .unknownOption(option):
            return "Unknown option: \(option)"
        case .cannotStartApp:
            return "Could not start Caff app"
        case .statusUnavailable:
            return "Caff status is unavailable"
        case let .invalidHookTarget(value):
            return "Invalid hook target: \(value). Use codex, claude, or all"
        }
    }
}

final class CaffCommandLineController {
    private let statusStore = CaffStatusStore()

    func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            throw CaffCommandLineError.missingCommand
        }
        let rest = Array(arguments.dropFirst())

        switch command {
        case "start":
            let options = try parseStartOptions(rest)
            try ensureAppRunning()
            RemoteCommandBridge.post(options)
            Thread.sleep(forTimeInterval: 0.35)
            print("start command sent")
        case "stop":
            try rejectUnexpectedOptions(rest)
            try ensureAppRunning()
            RemoteCommandBridge.post([RemoteCommandBridge.Key.action: "stop"])
            Thread.sleep(forTimeInterval: 0.35)
            print("stop command sent")
        case "agent-touch":
            let options = try parseAgentTouchOptions(rest)
            try ensureAppRunning()
            RemoteCommandBridge.post(options)
            Thread.sleep(forTimeInterval: 0.35)
            print("agent touch sent")
        case "install-hooks":
            let options = try parseHookOptions(rest, allowCooldown: true)
            let changes = try hookManager(cooldownSeconds: options.cooldownSeconds).install(targets: options.targets)
            printHookChanges(changes)
        case "remove-hooks":
            let options = try parseHookOptions(rest, allowCooldown: false)
            let changes = try hookManager(cooldownSeconds: options.cooldownSeconds).remove(targets: options.targets)
            printHookChanges(changes)
        case "status":
            try rejectUnexpectedOptions(rest)
            try ensureAppRunning()
            Thread.sleep(forTimeInterval: 0.35)
            try printStatus()
        default:
            throw CaffCommandLineError.unknownCommand(command)
        }
    }

    private func parseStartOptions(_ arguments: [String]) throws -> [String: String] {
        var result = [RemoteCommandBridge.Key.action: "start"]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--minutes":
                result[RemoteCommandBridge.Key.minutes] = try value(after: option, in: arguments, index: &index)
            case "--reason":
                result[RemoteCommandBridge.Key.reason] = try value(after: option, in: arguments, index: &index)
            case "--source":
                result[RemoteCommandBridge.Key.source] = try value(after: option, in: arguments, index: &index)
            case "--display-awake":
                result[RemoteCommandBridge.Key.displayAwake] = "true"
            default:
                throw CaffCommandLineError.unknownOption(option)
            }
            index += 1
        }
        _ = try RemoteControlParser.duration(minutes: result[RemoteCommandBridge.Key.minutes])
        _ = try RemoteControlParser.source(result[RemoteCommandBridge.Key.source])
        return result
    }

    private func parseAgentTouchOptions(_ arguments: [String]) throws -> [String: String] {
        var result = [RemoteCommandBridge.Key.action: "agent-touch"]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--source":
                result[RemoteCommandBridge.Key.agentSource] = try value(after: option, in: arguments, index: &index)
            case "--cooldown-seconds":
                result[RemoteCommandBridge.Key.cooldownSeconds] = try value(after: option, in: arguments, index: &index)
            default:
                throw CaffCommandLineError.unknownOption(option)
            }
            index += 1
        }
        _ = try RemoteControlParser.cooldownSeconds(result[RemoteCommandBridge.Key.cooldownSeconds])
        return result
    }

    private func parseHookOptions(_ arguments: [String], allowCooldown: Bool) throws -> HookOptions {
        var targets = AgentHookTarget.allCases
        var cooldownSeconds = AgentActivityCooldown.defaultCooldownSeconds
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--target":
                let value = try value(after: option, in: arguments, index: &index)
                targets = try hookTargets(value)
            case "--cooldown-seconds" where allowCooldown:
                let value = try value(after: option, in: arguments, index: &index)
                cooldownSeconds = try RemoteControlParser.cooldownSeconds(value)
            default:
                throw CaffCommandLineError.unknownOption(option)
            }
            index += 1
        }
        return HookOptions(targets: targets, cooldownSeconds: cooldownSeconds)
    }

    private func hookTargets(_ value: String) throws -> [AgentHookTarget] {
        if value == "all" {
            return AgentHookTarget.allCases
        }
        guard let target = AgentHookTarget(rawValue: value) else {
            throw CaffCommandLineError.invalidHookTarget(value)
        }
        return [target]
    }

    private func value(after option: String, in arguments: [String], index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw CaffCommandLineError.missingValue(option)
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    private func rejectUnexpectedOptions(_ arguments: [String]) throws {
        if let option = arguments.first {
            throw CaffCommandLineError.unknownOption(option)
        }
    }

    private func ensureAppRunning() throws {
        if waitForAppReadiness(timeout: 0.1) || isBundledAppRunning() {
            return
        }

        if let appURL = currentAppBundleURL() {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            guard waitForAppReadiness(timeout: 5) else {
                throw CaffCommandLineError.cannotStartApp
            }
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath())
        try process.run()
        guard waitForAppReadiness(timeout: 5) else {
            throw CaffCommandLineError.cannotStartApp
        }
    }

    private func printStatus() throws {
        guard let status = statusStore.read() else {
            throw CaffCommandLineError.statusUnavailable
        }
        print(status.cliDescription)
    }

    private func hookManager(cooldownSeconds: Int) -> AgentHookManager {
        AgentHookManager(
            homeDirectory: hookHomeDirectory(),
            executablePath: executablePath(),
            cooldownSeconds: cooldownSeconds
        )
    }

    private func printHookChanges(_ changes: [AgentHookChange]) {
        for change in changes {
            print(change.summary)
        }
    }

    private func hasLiveStatus() -> Bool {
        guard let status = statusStore.read() else {
            return false
        }
        return kill(status.appPID, 0) == 0
    }

    private func waitForAppReadiness(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if hasLiveStatus() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline

        return false
    }

    private func isBundledAppRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: RemoteCommandBridge.bundleIdentifier)
            .contains { $0.processIdentifier != getpid() }
    }

    private func currentAppBundleURL() -> URL? {
        let executableURL = URL(fileURLWithPath: executablePath()).standardizedFileURL
        let macOSURL = executableURL.deletingLastPathComponent()
        guard macOSURL.lastPathComponent == "MacOS",
              macOSURL.deletingLastPathComponent().lastPathComponent == "Contents" else {
            return nil
        }
        return macOSURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    private func executablePath() -> String {
        let rawPath = CommandLine.arguments[0]
        if rawPath.hasPrefix("/") {
            return rawPath
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(rawPath)
            .standardizedFileURL
            .path
    }

    private func hookHomeDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["CAFF_HOOK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private struct HookOptions {
        let targets: [AgentHookTarget]
        let cooldownSeconds: Int
    }
}
