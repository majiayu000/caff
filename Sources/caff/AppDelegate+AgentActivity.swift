import Foundation
import CaffCore

extension AppDelegate {
    func touchAgentActivity(source: String?, cooldownSeconds: Int = AgentActivityCooldown.defaultCooldownSeconds) {
        agentActivityState = AgentActivityCooldown.touch(
            source: source,
            cooldownSeconds: cooldownSeconds
        )
        scheduleAgentActivityTimer()
        syncAgentActivitySession()
        rebuildMenu()
        updateStatusTitle()
    }

    func cancelAgentActivityCooldown() {
        agentActivityState = nil
        agentActivitySummary = "Agent activity idle"
        agentActivityTimer?.invalidate()
        agentActivityTimer = nil
    }

    @objc func pollAgentActivity() {
        syncAgentActivitySession()
        rebuildMenu()
        updateStatusTitle()
    }

    private func scheduleAgentActivityTimer() {
        if agentActivityTimer != nil {
            return
        }

        let timer = Timer(
            timeInterval: 5,
            target: self,
            selector: #selector(pollAgentActivity),
            userInfo: nil,
            repeats: true
        )
        agentActivityTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func syncAgentActivitySession() {
        let evaluation = AgentActivityCooldown.evaluate(state: agentActivityState)
        agentActivitySummary = evaluation.summary

        guard evaluation.isKeepingAwake else {
            agentActivityState = nil
            agentActivityTimer?.invalidate()
            agentActivityTimer = nil
            if activeSession?.source == .agent {
                stopSession(result: .stopped)
            }
            return
        }

        if activeSession == nil {
            guard startSession(
                duration: agentActivityDuration(),
                source: .agent,
                reason: evaluation.reason
            ) else {
                cancelAgentActivityCooldown()
                return
            }
        }

        if activeSession?.source == .agent {
            refreshAgentActivitySession(evaluation)
        }
    }

    private func refreshAgentActivitySession(_ evaluation: AgentActivityEvaluation) {
        guard let state = agentActivityState,
              let cooldownUntil = evaluation.cooldownUntil else {
            return
        }

        let options = SessionOptions(
            duration: agentActivityDuration(),
            source: .agent,
            keepDisplayAwake: keepDisplayAwake,
            reason: evaluation.reason
        )
        let effectiveEndDate = currentSafetyPolicy().effectiveEndDate(
            for: options.duration,
            startedAt: state.lastActivityAt
        )

        do {
            if !powerAssertions.isRunning {
                try powerAssertions.start(options: options)
            }
            activeSession = WakeSession(
                options: options,
                startedAt: state.lastActivityAt,
                activeAssertions: powerAssertions.activeAssertions,
                endDate: min(cooldownUntil, effectiveEndDate ?? cooldownUntil)
            )
            lastErrorMessage = nil
        } catch {
            cancelAgentActivityCooldown()
            showError(error)
        }
    }

    private func agentActivityDuration() -> SessionDuration {
        let cooldownSeconds = agentActivityState?.cooldownSeconds ?? AgentActivityCooldown.defaultCooldownSeconds
        let minutes = max(1, Int(ceil(Double(cooldownSeconds) / 60.0)))
        return SessionDuration(label: "Agent Activity", minutes: minutes)
    }
}
