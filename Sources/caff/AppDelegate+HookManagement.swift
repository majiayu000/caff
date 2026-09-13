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
            let manager = hookManager()
            let changes: [AgentHookChange]
            do {
                changes = try manager.install()
            } catch {
                // Partial installs are not atomic across targets. Only revoke when a
                // conclusive scan finds no managed hooks; inconclusive preserves lease.
                revokeAgentTouchLeaseIfNoManagedHooksRemain(manager)
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
            do {
                let changes = try manager.remove()
                revokeAgentTouchLeaseIfNoManagedHooksRemain(manager)
                hookManagementStatus = .updated(targets: updatedHookTargets(changes))
                hookManagementStatusLabel.stringValue = hookManagementStatus.localizedText(text)
                showHookResult(title: text.hooksRemovedTitle, changes: changes)
            } catch {
                // Best-effort remaining-hook check on partial removal failures too.
                revokeAgentTouchLeaseIfNoManagedHooksRemain(manager)
                throw error
            }
        } catch {
            hookManagementStatus = .removeFailed
            hookManagementStatusLabel.stringValue = hookManagementStatus.localizedText(text)
            showError(error)
        }
    }

    private func hookManager() -> AgentHookManager {
        AgentHookManager(executablePath: Bundle.main.executablePath ?? "/Applications/Caff.app/Contents/MacOS/Caff")
    }

    /// Revokes the agent-touch lease only when a conclusive scan finds no managed hooks.
    private func revokeAgentTouchLeaseIfNoManagedHooksRemain(_ manager: AgentHookManager) {
        do {
            if try !manager.hasManagedHooks() {
                try? RemoteCommandUserAuthorization.revokeLease(scope: .agentTouch)
            }
        } catch {
            // Inconclusive — keep the lease so surviving hooks are not disabled.
        }
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
