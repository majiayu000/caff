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
            source: .agent,
            keepDisplayAwake: true,
            reason: "codex is active"
        ),
        startedAt: now,
        activeAssertions: [.displaySleep, .idleSystemSleep]
    )
    #expect(proofSession.sourceLabel == "Agent")
    #expect(proofSession.assertionSummary == "PreventUserIdleSystemSleep, NoDisplaySleepAssertion")
    #expect(proofSession.compactStatus(now: now) == "1h")
}

@Test func safetyPolicyAndHistory() throws {
    let policy = SafetyPolicy.standard
    #expect(policy.maximumSessionMinutes == 240)
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
            source: .agent,
            keepDisplayAwake: true,
            reason: "codex is active"
        ),
        startedAt: now,
        activeAssertions: [.displaySleep, .idleSystemSleep]
    )
    let historyEntry = SessionHistoryEntry(
        session: proofSession,
        endedAt: now.addingTimeInterval(120),
        result: .stopped
    )
    #expect(historyEntry.source == "Agent")
    #expect(historyEntry.reason == "codex is active")
    #expect(historyEntry.assertionKinds == ["PreventUserIdleSystemSleep", "NoDisplaySleepAssertion"])
    #expect(historyEntry.result == SessionHistoryResult.stopped)
    #expect(historyEntry.summary == "Stopped: Agent - 1 Hour")

    let legacyHistoryData = Data("""
    [
      {
        "id": "00000000-0000-0000-0000-000000000001",
        "startedAt": 1000,
        "endedAt": 1120,
        "source": "Launcher",
        "reason": "Agent command: codex",
        "durationLabel": "Indefinitely",
        "assertionKinds": ["PreventUserIdleSystemSleep"],
        "result": "exited",
        "errorMessage": "codex exited with status 0"
      }
    ]
    """.utf8)
    let legacyHistory = try JSONDecoder().decode([SessionHistoryEntry].self, from: legacyHistoryData)
    #expect(legacyHistory.first?.result == .stopped)
    #expect(legacyHistory.first?.summary == "Stopped: Launcher - Indefinitely")

    do {
        try policy.validate(duration: .oneHour, powerSource: .batteryPower)
        #expect(Bool(false), "long battery sessions should be blocked by default")
    } catch let error as SafetyPolicyError {
        #expect(error == .longSessionOnBattery(durationLabel: "1 Hour", thresholdMinutes: 60))
    }

    let permissivePolicy = SafetyPolicy(allowLongSessionsOnBattery: true)
    try permissivePolicy.validate(duration: .fourHours, powerSource: .batteryPower)
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

    for removedSource in ["process", "workspace"] {
        do {
            _ = try RemoteControlParser.source(removedSource)
            #expect(Bool(false), "remote control should reject removed trigger source \(removedSource)")
        } catch let error as RemoteControlError {
            #expect(error == .invalidSource(removedSource))
        }
    }
}

@Test func powerAssertionLifecycle() throws {
    let controller = PowerAssertionController()
    try controller.start(options: SessionOptions(duration: .thirtyMinutes, keepDisplayAwake: true))
    #expect(controller.isRunning)
    #expect(controller.activeAssertions == [.idleSystemSleep, .displaySleep])
    try controller.stop()
    #expect(!controller.isRunning)
}
