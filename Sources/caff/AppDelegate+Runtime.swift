import AppKit
import CaffCore

extension AppDelegate {
    func scheduleTimer() {
        updateTimer?.invalidate()
        let timer = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        updateTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func clearSessionState() {
        activeSession = nil
        updateTimer?.invalidate()
        updateTimer = nil
    }

    func recordHistory(
        for session: WakeSession,
        result: SessionHistoryResult,
        errorMessage: String? = nil,
        exitStatus: Int32? = nil,
        terminationReason: String? = nil
    ) {
        let entry = SessionHistoryEntry(
            session: session,
            result: result,
            errorMessage: errorMessage,
            exitStatus: exitStatus,
            terminationReason: terminationReason
        )
        history = historyStore.append(entry, to: history)
    }

    func historyMenuSummary() -> String {
        guard let latest = history.first else {
            return "History: Empty"
        }

        return "History: \(latest.summary)"
    }

    func sendNotification(title: String, body: String) {
        guard notificationsEnabled else {
            return
        }

        notificationBridge.send(title: title, body: body)
    }

    func writeStatusSnapshot() {
        let agentEvaluation = AgentActivityCooldown.evaluate(state: agentActivityState)
        statusStore.write(CaffStatusSnapshot.snapshot(
            session: activeSession,
            errorMessage: lastErrorMessage,
            agentActivity: agentEvaluation.summary,
            agentCooldownUntil: agentEvaluation.cooldownUntil
        ))
    }

    func showError(_ error: Error) {
        lastErrorMessage = String(describing: error)
        sendNotification(title: "Caff error", body: lastErrorMessage ?? "Unknown error")
        rebuildMenu()
        updateStatusTitle()

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Caff could not update the wake session"
        alert.informativeText = lastErrorMessage ?? "Unknown error"
        alert.runModal()
    }
}
