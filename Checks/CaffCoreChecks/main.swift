import CaffCore
import Darwin
import Foundation

var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures.append(message)
    }
}

let startDate = Date(timeIntervalSince1970: 1_000)
let now = Date(timeIntervalSince1970: 1_000)

check(
    SessionDuration.presets.map(\.label) == ["Indefinitely", "30 Minutes", "1 Hour", "4 Hours"],
    "duration presets should stay in menu order"
)
check(
    SessionDuration.indefinitely.endDate(from: startDate) == nil,
    "indefinite sessions should not have an end date"
)
check(
    SessionDuration.thirtyMinutes.endDate(from: startDate) == Date(timeIntervalSince1970: 2_800),
    "30 minute sessions should end after 1,800 seconds"
)
check(
    RemainingTimeFormatter.compactRemaining(until: nil) == "on",
    "indefinite remaining time should render as on"
)
check(
    RemainingTimeFormatter.compactRemaining(now: now, until: Date(timeIntervalSince1970: 8_500)) == "2h 5m",
    "hour remaining time should include whole hours and minutes"
)
check(
    RemainingTimeFormatter.compactRemaining(now: now, until: Date(timeIntervalSince1970: 3_699)) == "45m",
    "minute remaining time should round up"
)
check(
    RemainingTimeFormatter.compactRemaining(now: now, until: Date(timeIntervalSince1970: 1_030)) == "30s",
    "short remaining time should show seconds"
)

let options = SessionOptions(duration: .oneHour)
check(options.keepDisplayAwake == false, "display sleep prevention should be opt-in")
check(options.source == .manual, "manual should be the default session source")
check(options.reason == "Caff is keeping this Mac awake", "default assertion reason should be stable")

let proofSession = WakeSession(
    options: SessionOptions(duration: .oneHour, source: .process, keepDisplayAwake: true, reason: "codex is running"),
    startedAt: now,
    activeAssertions: [.displaySleep, .idleSystemSleep]
)
check(proofSession.sourceLabel == "Process", "session should expose source label")
check(
    proofSession.assertionSummary == "PreventUserIdleSystemSleep, NoDisplaySleepAssertion",
    "session should expose stable assertion proof"
)
check(proofSession.compactStatus(now: now) == "1h", "session should expose compact remaining status")

let policy = SafetyPolicy.standard
check(policy.maximumSessionMinutes == 240, "standard policy should cap sessions at four hours")
check(policy.stopGracePeriodSeconds == 60, "standard policy should keep a deterministic stop grace period")
check(
    policy.effectiveEndDate(for: .indefinitely, startedAt: startDate) == Date(timeIntervalSince1970: 15_400),
    "indefinite sessions should be capped by policy"
)
check(
    policy.sessionNotes(for: .indefinitely, powerSource: .acPower).contains("Indefinite is capped"),
    "policy notes should surface capped indefinite sessions"
)

let cappedSession = WakeSession(
    options: SessionOptions(duration: .indefinitely),
    startedAt: startDate,
    activeAssertions: [.idleSystemSleep],
    endDate: policy.effectiveEndDate(for: .indefinitely, startedAt: startDate)
)
check(cappedSession.compactStatus(now: startDate) == "4h", "policy-capped indefinite sessions should show capped time")

let historyEntry = SessionHistoryEntry(
    session: proofSession,
    endedAt: now.addingTimeInterval(120),
    result: .stopped
)
check(historyEntry.source == "Process", "history should record session source")
check(historyEntry.reason == "codex is running", "history should record session reason")
check(historyEntry.assertionKinds == ["PreventUserIdleSystemSleep", "NoDisplaySleepAssertion"], "history should record assertion proof")
check(historyEntry.result == .stopped, "history should record session result")
check(historyEntry.summary == "Stopped: Process - 1 Hour", "history should expose a compact summary")

let exitedHistoryEntry = SessionHistoryEntry(
    session: proofSession,
    endedAt: now.addingTimeInterval(180),
    result: .exited,
    errorMessage: "codex exited with status 0",
    exitStatus: 0,
    terminationReason: "exit"
)
check(exitedHistoryEntry.exitStatus == 0, "history should record launched command exit status")
check(exitedHistoryEntry.terminationReason == "exit", "history should record launched command termination reason")
check(exitedHistoryEntry.summary == "Exited: Process - exit 0", "history summary should expose launched command exit status")

do {
    try policy.validate(duration: .oneHour, powerSource: .batteryPower)
    failures.append("long battery sessions should be blocked by default")
} catch let error as SafetyPolicyError {
    check(
        error == .longSessionOnBattery(durationLabel: "1 Hour", thresholdMinutes: 60),
        "battery policy should report the blocked duration"
    )
} catch {
    failures.append("battery policy failed with unexpected error: \(error)")
}

let permissivePolicy = SafetyPolicy(allowLongSessionsOnBattery: true)
do {
    try permissivePolicy.validate(duration: .fourHours, powerSource: .batteryPower)
} catch {
    failures.append("explicitly allowed long battery sessions should pass validation: \(error)")
}

let processTriggerConfig = ProcessTriggerConfiguration(
    identifiers: ["codex", "python"],
    gracePeriodSeconds: 10
)
let processTrigger = ProcessTriggerEvaluator(configuration: processTriggerConfig)
let processCandidates = [
    ProcessCandidate(pid: 10, processName: "Codex", bundleIdentifier: "com.openai.codex", commandLine: "/Applications/Codex.app/Contents/MacOS/Codex"),
    ProcessCandidate(pid: 11, processName: "python3.12", commandLine: "/opt/homebrew/bin/python3.12 worker.py"),
    ProcessCandidate(pid: 12, processName: "zsh", commandLine: "/bin/zsh")
]
let processMatches = processTrigger.match(candidates: processCandidates)
check(processMatches.count == 2, "process trigger should match process names and versioned names once per process")
check(processMatches.contains { $0.identifier == "codex" && $0.candidate.pid == 10 }, "process trigger should match codex by name")
check(processMatches.contains { $0.identifier == "python" && $0.candidate.pid == 11 }, "process trigger should match versioned python processes")

let bundleTrigger = ProcessTriggerEvaluator(
    configuration: ProcessTriggerConfiguration(identifiers: ["com.openai.codex"])
)
check(
    bundleTrigger.match(candidates: processCandidates).contains { $0.identifier == "com.openai.codex" && $0.candidate.pid == 10 },
    "process trigger should match Codex by bundle identifier"
)

let triggerStart = Date(timeIntervalSince1970: 5_000)
let (activeEvaluation, activeState) = processTrigger.evaluate(
    candidates: [processCandidates[0]],
    previousState: .inactive,
    now: triggerStart
)
check(activeEvaluation.isKeepingAwake, "matching process should keep awake")
check(!activeEvaluation.isInGracePeriod, "matching process should not be in grace period")
check(activeEvaluation.reason == "Process trigger: Codex pid 10", "process trigger should explain the triggering process")

let (graceEvaluation, graceState) = processTrigger.evaluate(
    candidates: [],
    previousState: activeState,
    now: triggerStart.addingTimeInterval(5)
)
check(graceEvaluation.isKeepingAwake, "process trigger should keep awake during grace period")
check(graceEvaluation.isInGracePeriod, "process trigger should report grace period")
check(graceState == activeState, "grace period should preserve the last active match")

let (inactiveEvaluation, inactiveState) = processTrigger.evaluate(
    candidates: [],
    previousState: activeState,
    now: triggerStart.addingTimeInterval(11)
)
check(!inactiveEvaluation.isKeepingAwake, "process trigger should stop after grace expires")
check(inactiveState == .inactive, "expired process trigger should reset state")

let builtInCommands = AgentCommandDefinition.builtInExamples.map(\.name)
check(builtInCommands == ["codex", "claude", "npm test", "cargo test"], "agent launcher should include expected built-in commands")
do {
    let tokens = try AgentCommandParser.tokenizeArguments("--flag \"hello world\" 'two words'")
    check(tokens == ["--flag", "hello world", "two words"], "agent launcher should parse quoted arguments")
    let environment = try AgentCommandParser.parseEnvironment("FOO=bar, EMPTY=, PATH=/tmp/bin")
    check(environment == ["FOO": "bar", "EMPTY": "", "PATH": "/tmp/bin"], "agent launcher should parse environment assignments")
} catch {
    failures.append("agent command parsing failed: \(error)")
}

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
let (workspaceActive, workspaceState) = workspaceTrigger.evaluate(
    activities: [workspaceActivity],
    previousState: .inactive,
    now: triggerStart
)
check(workspaceTriggerConfig.normalizedPaths == ["/tmp/caff-workspace"], "workspace trigger should normalize configured paths")
check(workspaceActive.isKeepingAwake, "workspace activity should keep awake")
check(workspaceActive.reason == "Workspace trigger: caff-workspace: .git/index.lock", "workspace trigger should explain the activity signal")

let (workspaceGrace, workspaceGraceState) = workspaceTrigger.evaluate(
    activities: [],
    previousState: workspaceState,
    now: triggerStart.addingTimeInterval(5)
)
check(workspaceGrace.isKeepingAwake, "workspace trigger should keep awake during grace period")
check(workspaceGrace.isInGracePeriod, "workspace trigger should report grace period")
check(workspaceGraceState == workspaceState, "workspace grace should preserve last activity")

let (workspaceInactive, workspaceInactiveState) = workspaceTrigger.evaluate(
    activities: [],
    previousState: workspaceState,
    now: triggerStart.addingTimeInterval(11)
)
check(!workspaceInactive.isKeepingAwake, "workspace trigger should stop after grace expires")
check(workspaceInactiveState == .inactive, "expired workspace trigger should reset state")

do {
    let controller = PowerAssertionController()
    try controller.start(options: SessionOptions(duration: .thirtyMinutes, keepDisplayAwake: true))
    check(controller.isRunning, "controller should report running after start")
    check(
        controller.activeAssertions == [.idleSystemSleep, .displaySleep],
        "controller should create both requested assertions"
    )
    try controller.stop()
    check(controller.isRunning == false, "controller should report stopped after stop")
} catch {
    failures.append("power assertion lifecycle failed: \(error)")
}

if failures.isEmpty {
    print("CaffCore checks passed")
} else {
    for failure in failures {
        fputs("FAIL: \(failure)\n", stderr)
    }
    exit(1)
}
