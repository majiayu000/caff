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

    func stopCurrentSessionFromUI() {
        cancelAgentActivityCooldown()
        stopSession(result: .stopped)
    }

    func recordHistory(
        for session: WakeSession,
        result: SessionHistoryResult,
        errorMessage: String? = nil
    ) {
        let entry = SessionHistoryEntry(
            session: session,
            result: result,
            errorMessage: errorMessage
        )
        history = historyStore.append(entry, to: history)
    }

    func historyMenuSummary() -> String {
        guard let latest = history.first else {
            return text.localizedStatus("History: Empty")
        }

        return text.label(text.history, text.localizedStatus(latest.summary))
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
            agentCooldownUntil: agentEvaluation.cooldownUntil,
            lastAgentTouch: lastAgentTouch
        ))
    }

    func showError(_ error: Error) {
        lastErrorMessage = String(describing: error)
        sendNotification(title: text.caffError, body: lastErrorMessage ?? text.unknownError)
        rebuildMenu()
        updateStatusTitle()

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = text.updateSessionFailed
        alert.informativeText = lastErrorMessage ?? text.unknownError
        alert.runModal()
    }
}
