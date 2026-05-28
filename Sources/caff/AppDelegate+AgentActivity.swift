import Foundation
import CaffCore

extension AppDelegate {
    func touchAgentActivity(source: String?, cooldownSeconds: Int = AgentActivityCooldown.defaultCooldownSeconds) {
        let nextState = AgentActivityCooldown.touch(
            source: source,
            cooldownSeconds: cooldownSeconds
        )
        agentActivityState = nextState
        lastAgentTouch = AgentActivityTouch(state: nextState)
        scheduleAgentActivityTimer()
        syncAgentActivitySession()
        rebuildMenu()
        updateStatusTitle()
    }

    func cancelAgentActivityCooldown() {
        agentActivityState = nil
        agentActivitySummary = text.localizedStatus("Agent activity idle")
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
        agentActivitySummary = text.localizedStatus(evaluation.summary)

        guard evaluation.isKeepingAwake else {
            cancelAgentActivityCooldown()
            if activeSession?.source == .agent {
                stopSession(result: .stopped)
            }
            syncAutomaticTriggerSession()
            return
        }

        guard let state = agentActivityState,
              let cooldownUntil = evaluation.cooldownUntil else {
            cancelAgentActivityCooldown()
            return
        }

        let sessionEndDate = agentActivitySessionEndDate(
            state: state,
            cooldownUntil: cooldownUntil
        )
        if sessionEndDate <= Date() {
            cancelAgentActivityCooldown()
            if activeSession?.source == .agent {
                stopSession(result: .timedOut)
            }
            syncAutomaticTriggerSession()
            return
        }

        if activeSession == nil {
            guard startSession(
                duration: agentActivityDuration(),
                source: .agent,
                reason: text.localizedStatus(evaluation.reason)
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
            reason: text.localizedStatus(evaluation.reason)
        )

        do {
            if !powerAssertions.isRunning {
                try powerAssertions.start(options: options)
            }
            activeSession = WakeSession(
                options: options,
                startedAt: state.lastActivityAt,
                activeAssertions: powerAssertions.activeAssertions,
                endDate: agentActivitySessionEndDate(
                    state: state,
                    cooldownUntil: cooldownUntil
                )
            )
            lastErrorMessage = nil
        } catch {
            cancelAgentActivityCooldown()
            showError(error)
        }
    }

    private func agentActivitySessionEndDate(
        state: AgentActivityState,
        cooldownUntil: Date
    ) -> Date {
        AgentActivityCooldown.cappedCooldownEndDate(
            lastActivityAt: state.lastActivityAt,
            cooldownUntil: cooldownUntil,
            maximumSessionMinutes: currentSafetyPolicy().maximumSessionMinutes
        )
    }

    private func agentActivityDuration() -> SessionDuration {
        let cooldownSeconds = agentActivityState?.cooldownSeconds ?? AgentActivityCooldown.defaultCooldownSeconds
        let minutes = AgentActivityCooldown.policyDurationMinutes(cooldownSeconds: cooldownSeconds)
        return SessionDuration(label: text.choose(en: "Agent Activity", zh: "Agent 活动"), minutes: minutes)
    }
}
