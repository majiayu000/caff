import AppKit
import CaffCore

extension AppDelegate {
    @objc func installAgentHooks() {
        do {
            try RemoteCommandUserAuthorization.authorize(
                scope: .agentTouch,
                reason: "Authorize Caff agent-touch hooks to sign remote commands",
                leaseSeconds: RemoteCommandUserAuthorization.hookLeaseSeconds
            )
            let changes: [AgentHookChange]
            do {
                changes = try hookManager().install()
            } catch {
                try? RemoteCommandUserAuthorization.revokeLease(scope: .agentTouch)
                throw error
            }
            hookManagementStatus = .updated(targets: updatedHookTargets(changes))
            hookManagementStatusLabel.stringValue = hookManagementStatus.localizedText(text)
            showHookResult(title: text.hooksInstalledTitle, changes: changes)
        } catch {
            hookManagementStatus = .installFailed
            hookManagementStatusLabel.stringValue = hookManagementStatus.localizedText(text)
            showError(error)
        }
    }

    @objc func removeAgentHooks() {
        do {
            let manager = hookManager()
            let changes = try manager.remove()
            if try !manager.hasManagedHooks() {
                try RemoteCommandUserAuthorization.revokeLease(scope: .agentTouch)
            }
            hookManagementStatus = .updated(targets: updatedHookTargets(changes))
            hookManagementStatusLabel.stringValue = hookManagementStatus.localizedText(text)
            showHookResult(title: text.hooksRemovedTitle, changes: changes)
        } catch {
            hookManagementStatus = .removeFailed
            hookManagementStatusLabel.stringValue = hookManagementStatus.localizedText(text)
            showError(error)
        }
    }

    private func hookManager() -> AgentHookManager {
        AgentHookManager(executablePath: Bundle.main.executablePath ?? "/Applications/Caff.app/Contents/MacOS/Caff")
    }

    private func updatedHookTargets(_ changes: [AgentHookChange]) -> [String] {
        changes.filter(\.changed).map(\.target.label)
    }

    private func showHookResult(title: String, changes: [AgentHookChange]) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = changes.map(text.hookChangeSummary).joined(separator: "\n")
        alert.runModal()
    }
}

enum HookManagementDisplayStatus {
    case notInstalled
    case updated(targets: [String])
    case installFailed
    case removeFailed

    func localizedText(_ text: AppText) -> String {
        switch self {
        case .notInstalled:
            return text.hooksNotInstalled
        case .updated(let targets):
            return text.hooksUpdated(targets)
        case .installFailed:
            return text.hooksInstallFailed
        case .removeFailed:
            return text.hooksRemoveFailed
        }
    }
}
