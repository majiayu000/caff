import AppKit
import CaffCore

private enum AgentLauncherError: Error, CustomStringConvertible {
    case wakeSessionAlreadyRunning(String)

    var description: String {
        switch self {
        case let .wakeSessionAlreadyRunning(reason):
            return "A wake session is already running: \(reason)"
        }
    }
}

extension AppDelegate {
    func launchAgentCommand(_ command: AgentCommandDefinition) {
        guard activeSession == nil else {
            showError(AgentLauncherError.wakeSessionAlreadyRunning(activeSession?.reason ?? "Caff session"))
            return
        }
        let reason = "Agent command: \(command.name)"
        guard startSession(duration: .indefinitely, source: .launcher, reason: reason) else {
            return
        }

        do {
            let snapshot = try agentRunner.launch(command) { [weak self] exit in
                self?.handleAgentCommandExit(exit)
            }
            agentLauncherPanel.setStatus("Running \(snapshot.commandName) pid \(snapshot.pid)")
            rebuildMenu()
            updateStatusTitle()
        } catch {
            stopSession(result: .error, errorMessage: String(describing: error))
            showError(error)
        }
    }

    func stopCurrentSessionFromUI() {
        if activeSession?.source == .launcher, agentRunner.isRunning {
            promptLauncherStopChoice()
        } else {
            cancelAgentActivityCooldown()
            stopSession(result: .stopped)
        }
    }

    func releaseLauncherAssertionOnly() {
        guard activeSession?.source == .launcher else {
            return
        }
        cancelAgentActivityCooldown()
        releasedLauncherSession = activeSession
        stopSession(result: .stopped, errorMessage: "Wake assertion released while command kept running")
        if let snapshot = agentRunner.activeSnapshot {
            agentLauncherPanel.setStatus("Assertion released; \(snapshot.commandName) pid \(snapshot.pid) still running")
        }
    }

    func confirmTerminateAgentCommand() {
        guard let snapshot = agentRunner.activeSnapshot else {
            showError(AgentProcessRunnerError.notRunning)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Terminate \(snapshot.commandName)?"
        alert.informativeText = "This sends a termination signal to pid \(snapshot.pid)."
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        cancelAgentActivityCooldown()
        do {
            try agentRunner.terminate()
            agentLauncherPanel.setStatus("Terminating \(snapshot.commandName) pid \(snapshot.pid)")
        } catch {
            showError(error)
        }
    }

    private func promptLauncherStopChoice() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop launcher session"
        alert.informativeText = "Release only the wake assertion, or terminate the launched command too."
        alert.addButton(withTitle: "Release Assertion")
        alert.addButton(withTitle: "Terminate Command")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            releaseLauncherAssertionOnly()
        case .alertSecondButtonReturn:
            confirmTerminateAgentCommand()
        default:
            break
        }
    }

    private func handleAgentCommandExit(_ exit: AgentProcessExit) {
        agentLauncherPanel.setStatus(exit.summary)
        if activeSession?.source == .launcher {
            stopSession(
                result: .exited,
                errorMessage: exit.summary,
                exitStatus: exit.exitStatus,
                terminationReason: exit.terminationReason
            )
        } else if let releasedLauncherSession {
            recordHistory(
                for: releasedLauncherSession,
                result: .exited,
                errorMessage: exit.summary,
                exitStatus: exit.exitStatus,
                terminationReason: exit.terminationReason
            )
            self.releasedLauncherSession = nil
            sendNotification(title: "Caff task ended", body: exit.summary)
            rebuildMenu()
            updateStatusTitle()
        } else {
            sendNotification(title: "Caff task ended", body: exit.summary)
            rebuildMenu()
            updateStatusTitle()
        }
    }
}
