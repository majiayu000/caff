import AppKit
import CaffCore

extension AppDelegate {
    @objc func installAgentHooks() {
        do {
            let changes = try hookManager().install()
            hookManagementStatusLabel.stringValue = hookSummary(changes)
            showHookResult(title: text.hooksInstalledTitle, changes: changes)
        } catch {
            hookManagementStatusLabel.stringValue = text.hooksInstallFailed
            showError(error)
        }
    }

    @objc func removeAgentHooks() {
        do {
            let changes = try hookManager().remove()
            hookManagementStatusLabel.stringValue = hookSummary(changes)
            showHookResult(title: text.hooksRemovedTitle, changes: changes)
        } catch {
            hookManagementStatusLabel.stringValue = text.hooksRemoveFailed
            showError(error)
        }
    }

    private func hookManager() -> AgentHookManager {
        AgentHookManager(executablePath: Bundle.main.executablePath ?? "/Applications/Caff.app/Contents/MacOS/Caff")
    }

    private func hookSummary(_ changes: [AgentHookChange]) -> String {
        let updated = changes.filter(\.changed).map(\.target.label)
        return text.hooksUpdated(updated)
    }

    private func showHookResult(title: String, changes: [AgentHookChange]) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = changes.map(text.hookChangeSummary).joined(separator: "\n")
        alert.runModal()
    }
}
