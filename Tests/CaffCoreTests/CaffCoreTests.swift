import CaffCore
import Foundation
import Testing

private let startDate = Date(timeIntervalSince1970: 1_000)
private let now = Date(timeIntervalSince1970: 1_000)

@Test func sessionDurationAndProofStatus() {
    #expect(SessionDuration.presets.map(\.label) == ["Indefinitely", "30 Minutes", "1 Hour", "4 Hours"])
    #expect(SessionDuration.indefinitely.endDate(from: startDate) == nil)
    #expect(SessionDuration.thirtyMinutes.endDate(from: startDate) == Date(timeIntervalSince1970: 2_800))
    #expect(RemainingTimeFormatter.compactRemaining(until: nil) == "on")
    #expect(RemainingTimeFormatter.compactRemaining(now: now, until: Date(timeIntervalSince1970: 8_500)) == "2h 5m")
    #expect(RemainingTimeFormatter.compactRemaining(now: now, until: Date(timeIntervalSince1970: 3_699)) == "45m")
    #expect(RemainingTimeFormatter.compactRemaining(now: now, until: Date(timeIntervalSince1970: 1_030)) == "30s")

    let options = SessionOptions(duration: .oneHour)
    #expect(!options.keepDisplayAwake)
    #expect(options.source == .manual)
    #expect(options.reason == "Caff is keeping this Mac awake")

    let proofSession = WakeSession(
        options: SessionOptions(
            duration: .oneHour,
            source: .process,
            keepDisplayAwake: true,
            reason: "codex is running"
        ),
        startedAt: now,
        activeAssertions: [.displaySleep, .idleSystemSleep]
    )
    #expect(proofSession.sourceLabel == "Process")
    #expect(proofSession.assertionSummary == "PreventUserIdleSystemSleep, NoDisplaySleepAssertion")
    #expect(proofSession.compactStatus(now: now) == "1h")
}

@Test func safetyPolicyAndHistory() throws {
    let policy = SafetyPolicy.standard
    #expect(policy.maximumSessionMinutes == 240)
    #expect(policy.stopGracePeriodSeconds == 60)
    #expect(
        policy.effectiveEndDate(for: .indefinitely, startedAt: startDate) == Date(timeIntervalSince1970: 15_400)
    )
    #expect(policy.sessionNotes(for: .indefinitely, powerSource: .acPower).contains("Indefinite is capped"))

    let cappedSession = WakeSession(
        options: SessionOptions(duration: .indefinitely),
        startedAt: startDate,
        activeAssertions: [.idleSystemSleep],
        endDate: policy.effectiveEndDate(for: .indefinitely, startedAt: startDate)
    )
    #expect(cappedSession.compactStatus(now: startDate) == "4h")

    let proofSession = WakeSession(
        options: SessionOptions(
            duration: .oneHour,
            source: .process,
            keepDisplayAwake: true,
            reason: "codex is running"
        ),
        startedAt: now,
        activeAssertions: [.displaySleep, .idleSystemSleep]
    )
    let historyEntry = SessionHistoryEntry(
        session: proofSession,
        endedAt: now.addingTimeInterval(120),
        result: .stopped
    )
    #expect(historyEntry.source == "Process")
    #expect(historyEntry.reason == "codex is running")
    #expect(historyEntry.assertionKinds == ["PreventUserIdleSystemSleep", "NoDisplaySleepAssertion"])
    #expect(historyEntry.result == SessionHistoryResult.stopped)
    #expect(historyEntry.summary == "Stopped: Process - 1 Hour")

    do {
        try policy.validate(duration: .oneHour, powerSource: .batteryPower)
        #expect(Bool(false), "long battery sessions should be blocked by default")
    } catch let error as SafetyPolicyError {
        #expect(error == .longSessionOnBattery(durationLabel: "1 Hour", thresholdMinutes: 60))
    }

    let permissivePolicy = SafetyPolicy(allowLongSessionsOnBattery: true)
    try permissivePolicy.validate(duration: .fourHours, powerSource: .batteryPower)
}

@Test func processTriggerEvaluation() {
    let processTrigger = ProcessTriggerEvaluator(
        configuration: ProcessTriggerConfiguration(
            identifiers: ["codex", "python"],
            gracePeriodSeconds: 10
        )
    )
    let processCandidates = [
        ProcessCandidate(
            pid: 10,
            processName: "Codex",
            bundleIdentifier: "com.openai.codex",
            commandLine: "/Applications/Codex.app/Contents/MacOS/Codex"
        ),
        ProcessCandidate(
            pid: 11,
            processName: "python3.12",
            commandLine: "/opt/homebrew/bin/python3.12 worker.py"
        ),
        ProcessCandidate(pid: 12, processName: "zsh", commandLine: "/bin/zsh")
    ]

    let processMatches = processTrigger.match(candidates: processCandidates)
    #expect(processMatches.count == 2)
    #expect(processMatches.contains { $0.identifier == "codex" && $0.candidate.pid == 10 })
    #expect(processMatches.contains { $0.identifier == "python" && $0.candidate.pid == 11 })

    let bundleTrigger = ProcessTriggerEvaluator(
        configuration: ProcessTriggerConfiguration(identifiers: ["com.openai.codex"])
    )
    #expect(
        bundleTrigger.match(candidates: processCandidates)
            .contains { $0.identifier == "com.openai.codex" && $0.candidate.pid == 10 }
    )

    let triggerStart = Date(timeIntervalSince1970: 5_000)
    let (activeEvaluation, activeState) = processTrigger.evaluate(
        candidates: [processCandidates[0]],
        previousState: .inactive,
        now: triggerStart
    )
    #expect(activeEvaluation.isKeepingAwake)
    #expect(!activeEvaluation.isInGracePeriod)
    #expect(activeEvaluation.reason == "Process trigger: Codex pid 10")

    let (graceEvaluation, graceState) = processTrigger.evaluate(
        candidates: [],
        previousState: activeState,
        now: triggerStart.addingTimeInterval(5)
    )
    #expect(graceEvaluation.isKeepingAwake)
    #expect(graceEvaluation.isInGracePeriod)
    #expect(graceState == activeState)

    let (inactiveEvaluation, inactiveState) = processTrigger.evaluate(
        candidates: [],
        previousState: activeState,
        now: triggerStart.addingTimeInterval(11)
    )
    #expect(!inactiveEvaluation.isKeepingAwake)
    #expect(inactiveState == .inactive)
}

@Test func remoteControlParsing() throws {
    #expect(try RemoteControlParser.duration(minutes: "45").minutes == 45)
    #expect(try RemoteControlParser.duration(minutes: nil) == .indefinitely)
    #expect(try RemoteControlParser.source("url") == .url)
    #expect(RemoteControlParser.bool("true"))

    do {
        _ = try RemoteControlParser.duration(minutes: "0")
        #expect(Bool(false), "remote control should reject invalid durations")
    } catch let error as RemoteControlError {
        #expect(error == .invalidDuration("0"))
    }
}

@Test func workspaceTriggerEvaluation() {
    let workspaceTriggerConfig = WorkspaceTriggerConfiguration(
        paths: ["/tmp/caff-workspace"],
        recentActivityWindowSeconds: 300,
        gracePeriodSeconds: 10
    )
    let workspaceTrigger = WorkspaceTriggerEvaluator(configuration: workspaceTriggerConfig)
    let workspaceActivity = WorkspaceActivity(
        path: "/tmp/caff-workspace",
        signal: .gitIndexLock
    )
    let triggerStart = Date(timeIntervalSince1970: 5_000)

    let (workspaceActive, workspaceState) = workspaceTrigger.evaluate(
        activities: [workspaceActivity],
        previousState: .inactive,
        now: triggerStart
    )
    #expect(workspaceTriggerConfig.normalizedPaths == ["/tmp/caff-workspace"])
    #expect(workspaceActive.isKeepingAwake)
    #expect(workspaceActive.reason == "Workspace trigger: caff-workspace: .git/index.lock")

    let (workspaceGrace, workspaceGraceState) = workspaceTrigger.evaluate(
        activities: [],
        previousState: workspaceState,
        now: triggerStart.addingTimeInterval(5)
    )
    #expect(workspaceGrace.isKeepingAwake)
    #expect(workspaceGrace.isInGracePeriod)
    #expect(workspaceGraceState == workspaceState)

    let (workspaceInactive, workspaceInactiveState) = workspaceTrigger.evaluate(
        activities: [],
        previousState: workspaceState,
        now: triggerStart.addingTimeInterval(11)
    )
    #expect(!workspaceInactive.isKeepingAwake)
    #expect(workspaceInactiveState == .inactive)
}

@Test func powerAssertionLifecycle() throws {
    let controller = PowerAssertionController()
    try controller.start(options: SessionOptions(duration: .thirtyMinutes, keepDisplayAwake: true))
    #expect(controller.isRunning)
    #expect(controller.activeAssertions == [.idleSystemSleep, .displaySleep])
    try controller.stop()
    #expect(!controller.isRunning)
}
