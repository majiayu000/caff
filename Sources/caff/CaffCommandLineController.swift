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

    var description: String {
        switch self {
        case .missingCommand:
            return "Missing command. Use: caff start|stop|status"
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
}
