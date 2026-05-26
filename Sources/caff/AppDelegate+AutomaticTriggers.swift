import Foundation
import CaffCore

extension AppDelegate {
    @objc func toggleProcessTrigger() {
        processTriggerEnabled.toggle()
        processTriggerState = .inactive
        processTriggerSummary = processTriggerEnabled ? "Process trigger watching" : "Process trigger idle"

        if processTriggerEnabled {
            scheduleProcessTriggerTimer()
            pollProcessTrigger()
        } else {
            processTriggerTimer?.invalidate()
            processTriggerTimer = nil
            processTriggerKeepingAwake = false
            processTriggerReason = "Process trigger"
            syncAutomaticTriggerSession()
        }

        rebuildMenu()
        updateStatusTitle()
    }

    @objc func toggleWorkspaceTrigger() {
        workspaceTriggerEnabled.toggle()
        workspaceTriggerState = .inactive
        workspaceTriggerSummary = workspaceTriggerEnabled ? "Workspace trigger watching" : "Workspace trigger idle"

        if workspaceTriggerEnabled {
            scheduleWorkspaceTriggerTimer()
            pollWorkspaceTrigger()
        } else {
            workspaceTriggerTimer?.invalidate()
            workspaceTriggerTimer = nil
            workspaceTriggerKeepingAwake = false
            workspaceTriggerReason = "Workspace trigger"
            syncAutomaticTriggerSession()
        }

        rebuildMenu()
        updateStatusTitle()
    }

    @objc func pollProcessTrigger() {
        guard processTriggerEnabled else {
            return
        }

        let evaluator = ProcessTriggerEvaluator(configuration: currentProcessTriggerConfiguration())
        let (evaluation, nextState) = evaluator.evaluate(
            candidates: ProcessListScanner.snapshot(),
            previousState: processTriggerState
        )
        processTriggerState = nextState
        processTriggerSummary = evaluation.summary
        processTriggerKeepingAwake = evaluation.isKeepingAwake
        processTriggerReason = evaluation.reason
        syncAutomaticTriggerSession()

        rebuildMenu()
        updateStatusTitle()
    }

    @objc func pollWorkspaceTrigger() {
        guard workspaceTriggerEnabled else {
            return
        }

        let configuration = currentWorkspaceTriggerConfiguration()
        let evaluator = WorkspaceTriggerEvaluator(configuration: configuration)
        let (evaluation, nextState) = evaluator.evaluate(
            activities: WorkspaceActivityScanner.activities(configuration: configuration),
            previousState: workspaceTriggerState
        )
        workspaceTriggerState = nextState
        workspaceTriggerSummary = evaluation.summary
        workspaceTriggerKeepingAwake = evaluation.isKeepingAwake
        workspaceTriggerReason = evaluation.reason
        syncAutomaticTriggerSession()

        rebuildMenu()
        updateStatusTitle()
    }

    func scheduleProcessTriggerTimer() {
        processTriggerTimer?.invalidate()
        let timer = Timer(
            timeInterval: 5,
            target: self,
            selector: #selector(pollProcessTrigger),
            userInfo: nil,
            repeats: true
        )
        processTriggerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func scheduleWorkspaceTriggerTimer() {
        workspaceTriggerTimer?.invalidate()
        let timer = Timer(
            timeInterval: 15,
            target: self,
            selector: #selector(pollWorkspaceTrigger),
            userInfo: nil,
            repeats: true
        )
        workspaceTriggerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func currentProcessTriggerConfiguration() -> ProcessTriggerConfiguration {
        let identifiers = processIdentifiersField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return ProcessTriggerConfiguration(
            identifiers: identifiers.isEmpty ? ProcessTriggerConfiguration.agentDefaults.identifiers : identifiers,
            gracePeriodSeconds: currentSafetyPolicy().stopGracePeriodSeconds
        )
    }

    private func currentWorkspaceTriggerConfiguration() -> WorkspaceTriggerConfiguration {
        let paths = workspacePathsField.stringValue
            .split { character in
                character == "," || character == "\n"
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return WorkspaceTriggerConfiguration(
            paths: paths,
            recentActivityWindowSeconds: 300,
            gracePeriodSeconds: currentSafetyPolicy().stopGracePeriodSeconds
        )
    }

    private func syncAutomaticTriggerSession() {
        guard let desiredTrigger = desiredAutomaticTrigger() else {
            if activeSession?.source == .process || activeSession?.source == .workspace {
                stopSession(result: .stopped)
            }
            return
        }

        guard let activeSession else {
            let started = startSession(
                duration: .indefinitely,
                source: desiredTrigger.source,
                reason: desiredTrigger.reason
            )
            if !started {
                disableFailedAutomaticTrigger(desiredTrigger.source)
            }
            return
        }

        guard activeSession.source == .process || activeSession.source == .workspace else {
            return
        }

        if activeSession.source != desiredTrigger.source || activeSession.reason != desiredTrigger.reason {
            self.activeSession = activeSession.updatingSource(desiredTrigger.source, reason: desiredTrigger.reason)
        }
    }

    private func desiredAutomaticTrigger() -> (source: SessionSource, reason: String)? {
        if workspaceTriggerEnabled, workspaceTriggerKeepingAwake {
            return (.workspace, workspaceTriggerReason)
        }

        if processTriggerEnabled, processTriggerKeepingAwake {
            return (.process, processTriggerReason)
        }

        return nil
    }

    private func disableFailedAutomaticTrigger(_ source: SessionSource) {
        switch source {
        case .process:
            processTriggerEnabled = false
            processTriggerKeepingAwake = false
            processTriggerTimer?.invalidate()
            processTriggerTimer = nil
        case .workspace:
            workspaceTriggerEnabled = false
            workspaceTriggerKeepingAwake = false
            workspaceTriggerTimer?.invalidate()
            workspaceTriggerTimer = nil
        case .manual, .agent, .cli, .url:
            break
        }
    }
}
