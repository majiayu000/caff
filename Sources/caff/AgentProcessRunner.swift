import CaffCore
import Foundation

enum AgentProcessRunnerError: Error, CustomStringConvertible {
    case alreadyRunning(commandName: String, pid: Int32)
    case missingWorkingDirectory(String)
    case missingExecutable(String)
    case notRunning

    var description: String {
        switch self {
        case let .alreadyRunning(commandName, pid):
            return "\(commandName) is already running as pid \(pid)"
        case let .missingWorkingDirectory(path):
            return "Working directory does not exist: \(path)"
        case let .missingExecutable(path):
            return "Executable does not exist: \(path)"
        case .notRunning:
            return "No launched agent command is running"
        }
    }
}

struct AgentProcessSnapshot: Equatable {
    let commandName: String
    let pid: Int32
    let startedAt: Date
}

struct AgentProcessExit: Equatable {
    let commandName: String
    let pid: Int32
    let exitStatus: Int32
    let terminationReason: String

    var summary: String {
        "\(commandName) pid \(pid) exited with status \(exitStatus) (\(terminationReason))"
    }
}

final class AgentProcessRunner {
    private var process: Process?
    private var snapshot: AgentProcessSnapshot?

    var isRunning: Bool {
        process?.isRunning == true
    }

    var activeSnapshot: AgentProcessSnapshot? {
        guard isRunning else {
            return nil
        }
        return snapshot
    }

    func launch(_ command: AgentCommandDefinition, onExit: @escaping (AgentProcessExit) -> Void) throws -> AgentProcessSnapshot {
        if let activeSnapshot {
            throw AgentProcessRunnerError.alreadyRunning(commandName: activeSnapshot.commandName, pid: activeSnapshot.pid)
        }
        let executable = command.executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executable.isEmpty else {
            throw AgentCommandParseError.emptyExecutable
        }

        let process = Process()
        if executable.contains("/") {
            let executableURL = URL(fileURLWithPath: PathExpansion.expandTilde(executable))
            guard FileManager.default.fileExists(atPath: executableURL.path) else {
                throw AgentProcessRunnerError.missingExecutable(executableURL.path)
            }
            process.executableURL = executableURL
            process.arguments = command.arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + command.arguments
        }

        let workingDirectory = PathExpansion.expandTilde(command.workingDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AgentProcessRunnerError.missingWorkingDirectory(workingDirectory)
        }
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
        process.terminationHandler = { [weak self] terminatedProcess in
            let exit = AgentProcessExit(
                commandName: command.name,
                pid: terminatedProcess.processIdentifier,
                exitStatus: terminatedProcess.terminationStatus,
                terminationReason: Self.reasonLabel(terminatedProcess.terminationReason)
            )
            DispatchQueue.main.async {
                if self?.process === terminatedProcess {
                    self?.process = nil
                    self?.snapshot = nil
                }
                onExit(exit)
            }
        }

        try process.run()
        let snapshot = AgentProcessSnapshot(commandName: command.name, pid: process.processIdentifier, startedAt: Date())
        self.process = process
        self.snapshot = snapshot
        return snapshot
    }

    func terminate() throws {
        guard let process, process.isRunning else {
            throw AgentProcessRunnerError.notRunning
        }
        process.terminate()
    }

    private static func reasonLabel(_ reason: Process.TerminationReason) -> String {
        switch reason {
        case .exit:
            return "exit"
        case .uncaughtSignal:
            return "signal"
        @unknown default:
            return "unknown"
        }
    }
}
