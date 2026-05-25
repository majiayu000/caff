import AppKit
import CaffCore
import Foundation

enum ProcessListScanner {
    static func snapshot() -> [ProcessCandidate] {
        var candidatesByPID = cliProcesses()

        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            let processName = app.executableURL?.lastPathComponent ?? app.localizedName ?? "pid-\(pid)"
            let existing = candidatesByPID[pid]
            candidatesByPID[pid] = ProcessCandidate(
                pid: pid,
                processName: existing?.processName ?? processName,
                bundleIdentifier: app.bundleIdentifier,
                commandLine: existing?.commandLine ?? processName
            )
        }

        return candidatesByPID.values.sorted { $0.pid < $1.pid }
    }

    private static func cliProcesses() -> [Int32: ProcessCandidate] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=", "-o", "comm=", "-o", "args="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return [:]
        }

        guard process.terminationStatus == 0 else {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return [:]
        }

        var candidates: [Int32: ProcessCandidate] = [:]
        for line in output.split(separator: "\n") {
            guard let candidate = parsePSLine(String(line)) else {
                continue
            }
            candidates[candidate.pid] = candidate
        }

        return candidates
    }

    private static func parsePSLine(_ line: String) -> ProcessCandidate? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)

        guard parts.count >= 2,
              let pid = Int32(parts[0]) else {
            return nil
        }

        let commandPath = String(parts[1])
        let commandLine = parts.count == 3 ? String(parts[2]) : commandPath
        let processName = URL(fileURLWithPath: commandPath).lastPathComponent

        return ProcessCandidate(
            pid: pid,
            processName: processName,
            commandLine: commandLine
        )
    }
}
