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
check(
    RemainingTimeFormatter.compactRemaining(untilSeconds: 1_800) == "30m",
    "remaining seconds should render compact durations"
)

let options = SessionOptions(duration: .oneHour)
check(options.keepDisplayAwake == false, "display sleep prevention should be opt-in")
check(options.source == .manual, "manual should be the default session source")
check(options.reason == "Caff is keeping this Mac awake", "default assertion reason should be stable")

let proofSession = WakeSession(
    options: SessionOptions(duration: .oneHour, source: .agent, keepDisplayAwake: true, reason: "codex is active"),
    startedAt: now,
    activeAssertions: [.displaySleep, .idleSystemSleep]
)
check(proofSession.sourceLabel == "Agent", "session should expose source label")
check(
    proofSession.assertionSummary == "PreventUserIdleSystemSleep, NoDisplaySleepAssertion",
    "session should expose stable assertion proof"
)
check(proofSession.compactStatus(now: now) == "1h", "session should expose compact remaining status")

let policy = SafetyPolicy.standard
check(policy.maximumSessionMinutes == 240, "standard policy should cap sessions at four hours")
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
check(historyEntry.source == "Agent", "history should record session source")
check(historyEntry.reason == "codex is active", "history should record session reason")
check(historyEntry.assertionKinds == ["PreventUserIdleSystemSleep", "NoDisplaySleepAssertion"], "history should record assertion proof")
check(historyEntry.result == .stopped, "history should record session result")
check(historyEntry.summary == "Stopped: Agent - 1 Hour", "history should expose a compact summary")

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

do {
    try policy.validate(duration: .oneHour, powerSource: .unknown)
    failures.append("long sessions on unknown power should be blocked by default (fail closed)")
} catch let error as SafetyPolicyError {
    check(
        error == .longSessionOnBattery(durationLabel: "1 Hour", thresholdMinutes: 60),
        "unknown power policy should report the blocked duration"
    )
} catch {
    failures.append("unknown power policy failed with unexpected error: \(error)")
}

check(
    policy.sessionNotes(for: .oneHour, powerSource: .unknown).contains("Long battery blocked"),
    "policy notes should surface long-session block for unknown power"
)

let permissivePolicy = SafetyPolicy(allowLongSessionsOnBattery: true)
do {
    try permissivePolicy.validate(duration: .fourHours, powerSource: .batteryPower)
    try permissivePolicy.validate(duration: .fourHours, powerSource: .unknown)
} catch {
    failures.append("explicitly allowed long battery/unknown sessions should pass validation: \(error)")
}

let agentTouch = Date(timeIntervalSince1970: 7_000)
let agentState = AgentActivityCooldown.touch(source: " codex ", cooldownSeconds: 1_800, now: agentTouch)
let activeAgentEvaluation = AgentActivityCooldown.evaluate(
    state: agentState,
    now: agentTouch.addingTimeInterval(60)
)
check(agentState.source == "codex", "agent activity should normalize source labels")
check(activeAgentEvaluation.isKeepingAwake, "agent activity should keep awake during cooldown")
check(
    activeAgentEvaluation.cooldownUntil == agentTouch.addingTimeInterval(1_800),
    "agent activity should expose cooldown end"
)
check(
    activeAgentEvaluation.summary == "Agent activity: codex, sleep allowed in 29m",
    "agent activity should expose remaining cooldown"
)
let refreshedAgentState = AgentActivityCooldown.touch(
    source: "claude",
    cooldownSeconds: 1_800,
    now: agentTouch.addingTimeInterval(1_700)
)
check(
    AgentActivityCooldown.evaluate(state: refreshedAgentState, now: agentTouch.addingTimeInterval(1_750)).isKeepingAwake,
    "later agent activity should refresh the cooldown"
)
check(
    !AgentActivityCooldown.evaluate(state: agentState, now: agentTouch.addingTimeInterval(1_801)).isKeepingAwake,
    "agent activity should expire after cooldown"
)

do {
    let remoteDuration = try RemoteControlParser.duration(minutes: "45")
    let defaultRemoteDuration = try RemoteControlParser.duration(minutes: nil)
    let urlRemoteSource = try RemoteControlParser.source("url")
    let remoteCooldown = try RemoteControlParser.cooldownSeconds("1800")
    let defaultRemoteCooldown = try RemoteControlParser.cooldownSeconds(nil)
    check(remoteDuration.minutes == 45, "remote control should parse minute durations")
    check(defaultRemoteDuration == .indefinitely, "remote control should default to indefinite duration")
    check(urlRemoteSource == .url, "remote control should parse URL source")
    check(remoteCooldown == 1_800, "remote control should parse agent cooldown")
    check(defaultRemoteCooldown == AgentActivityCooldown.defaultCooldownSeconds, "remote control should default agent cooldown")
    check(RemoteControlParser.bool("true"), "remote control should parse true booleans")
} catch {
    failures.append("remote control parsing failed: \(error)")
}

do {
    _ = try RemoteControlParser.duration(minutes: "0")
    failures.append("remote control should reject invalid durations")
} catch let error as RemoteControlError {
    check(error == .invalidDuration("0"), "remote control should report invalid duration value")
} catch {
    failures.append("remote control duration rejected with unexpected error: \(error)")
}

do {
    let maxMinutes = SafetyPolicy.standard.maximumSessionMinutes
    let atMax = try RemoteControlParser.duration(minutes: "\(maxMinutes)")
    check(atMax.minutes == maxMinutes, "remote control should accept the maximum session minutes")
} catch {
    failures.append("remote control maximum duration parsing failed: \(error)")
}

do {
    let overMax = "\(SafetyPolicy.standard.maximumSessionMinutes + 1)"
    _ = try RemoteControlParser.duration(minutes: overMax)
    failures.append("remote control should reject durations above maximum session minutes")
} catch let error as RemoteControlError {
    check(
        error == .invalidDuration("\(SafetyPolicy.standard.maximumSessionMinutes + 1)"),
        "remote control should report oversized duration value"
    )
} catch {
    failures.append("remote control oversized duration rejected with unexpected error: \(error)")
}

do {
    _ = try RemoteControlParser.duration(minutes: "\(Int.max)")
    failures.append("remote control should reject Int.max-scale durations")
} catch let error as RemoteControlError {
    check(error == .invalidDuration("\(Int.max)"), "remote control should report Int.max-scale duration value")
} catch {
    failures.append("remote control Int.max duration rejected with unexpected error: \(error)")
}

let overflowingDuration = SessionDuration(label: "Overflow", minutes: Int.max)
check(overflowingDuration.timeInterval == nil, "session duration timeInterval should return nil on overflow")
check(overflowingDuration.endDate(from: startDate) == nil, "session duration endDate should return nil on overflow")

let maxSafeMinutes = Int.max / 60
let safeDuration = SessionDuration(label: "Safe Max", minutes: maxSafeMinutes)
check(
    safeDuration.timeInterval == TimeInterval(maxSafeMinutes * 60),
    "session duration timeInterval should accept the largest non-overflowing minutes"
)
let unsafeDuration = SessionDuration(label: "Unsafe", minutes: maxSafeMinutes + 1)
check(unsafeDuration.timeInterval == nil, "session duration timeInterval should reject overflowing minutes")


for removedSource in ["process", "workspace"] {
    do {
        _ = try RemoteControlParser.source(removedSource)
        failures.append("remote control should reject removed trigger source \(removedSource)")
    } catch let error as RemoteControlError {
        check(error == .invalidSource(removedSource), "remote control should report removed trigger source \(removedSource)")
    } catch {
        failures.append("remote control source \(removedSource) rejected with unexpected error: \(error)")
    }
}

do {
    _ = try RemoteControlParser.cooldownSeconds("0")
    failures.append("remote control should reject invalid cooldown seconds")
} catch let error as RemoteControlError {
    check(error == .invalidCooldownSeconds("0"), "remote control should report invalid cooldown value")
} catch {
    failures.append("remote control cooldown rejected with unexpected error: \(error)")
}

var remotePresentation = RemoteErrorPresentation(minimumInterval: 5)
let remoteStart = Date(timeIntervalSince1970: 5_000)
check(
    RemoteErrorPresentation.defaultMinimumInterval == 5,
    "remote error presentation should default to a 5 second notification interval"
)
check(
    remotePresentation.shouldEmitNotification(now: remoteStart),
    "first remote error notification should be allowed"
)
check(
    remotePresentation.shouldEmitNotification(now: remoteStart.addingTimeInterval(1)) == false,
    "remote error notifications should be rate-limited inside the interval"
)
check(
    remotePresentation.shouldEmitNotification(now: remoteStart.addingTimeInterval(5)),
    "remote error notifications should resume after the minimum interval"
)

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
