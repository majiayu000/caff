import AppKit
import CaffCore

extension AppDelegate {
    @objc func installAgentHooks() {
        do {
            let changes = try hookManager().install()
            hookManagementStatusLabel.stringValue = hookSummary(changes)
            showHookResult(title: "Agent hooks installed", changes: changes)
        } catch {
            hookManagementStatusLabel.stringValue = "Hooks: Install failed"
            showError(error)
        }
    }

    @objc func removeAgentHooks() {
        do {
            let changes = try hookManager().remove()
            hookManagementStatusLabel.stringValue = hookSummary(changes)
            showHookResult(title: "Agent hooks removed", changes: changes)
        } catch {
            hookManagementStatusLabel.stringValue = "Hooks: Remove failed"
            showError(error)
        }
    }

    private func hookManager() -> AgentHookManager {
        AgentHookManager(executablePath: Bundle.main.executablePath ?? "/Applications/Caff.app/Contents/MacOS/Caff")
    }

    private func hookSummary(_ changes: [AgentHookChange]) -> String {
        let updated = changes.filter(\.changed).map(\.target.label)
        if updated.isEmpty {
            return "Hooks: Already current"
        }
        return "Hooks: Updated \(updated.joined(separator: ", "))"
    }

    private func showHookResult(title: String, changes: [AgentHookChange]) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = changes.map(\.summary).joined(separator: "\n")
        alert.runModal()
    }
}
