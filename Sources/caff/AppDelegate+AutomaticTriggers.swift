import Foundation
import CaffCore

extension AppDelegate {
    @objc func toggleProcessTrigger() {
        processTriggerEnabled.toggle()
        processTriggerState = .inactive
        processTriggerSummary = processTriggerEnabled ? text.localizedStatus("Process trigger watching") : text.localizedStatus("Process trigger idle")

        if processTriggerEnabled {
            scheduleProcessTriggerTimer()
            pollProcessTrigger()
        } else {
            processTriggerTimer?.invalidate()
            processTriggerTimer = nil
            processTriggerKeepingAwake = false
            processTriggerReason = text.localizedStatus("Process trigger")
            syncAutomaticTriggerSession()
        }

        rebuildMenu()
        updateStatusTitle()
    }

    @objc func toggleWorkspaceTrigger() {
        workspaceTriggerEnabled.toggle()
        workspaceTriggerState = .inactive
        workspaceTriggerSummary = workspaceTriggerEnabled ? text.localizedStatus("Workspace trigger watching") : text.localizedStatus("Workspace trigger idle")

        if workspaceTriggerEnabled {
            scheduleWorkspaceTriggerTimer()
            pollWorkspaceTrigger()
        } else {
            workspaceTriggerTimer?.invalidate()
            workspaceTriggerTimer = nil
            workspaceTriggerKeepingAwake = false
            workspaceTriggerReason = text.localizedStatus("Workspace trigger")
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
        processTriggerSummary = text.localizedStatus(evaluation.summary)
        processTriggerKeepingAwake = evaluation.isKeepingAwake
        processTriggerReason = text.localizedStatus(evaluation.reason)
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
        workspaceTriggerSummary = text.localizedStatus(evaluation.summary)
        workspaceTriggerKeepingAwake = evaluation.isKeepingAwake
        workspaceTriggerReason = text.localizedStatus(evaluation.reason)
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
            identifiers: identifiers,
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

    func syncAutomaticTriggerSession() {
        guard let desiredTrigger = desiredAutomaticTrigger() else {
            if activeSession?.source == .process || activeSession?.source == .workspace {
                stopSession(result: .stopped)
                pollAgentActivity()
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
