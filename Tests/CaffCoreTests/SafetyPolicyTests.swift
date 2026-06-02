import CaffCore
import Foundation
import Testing

private let startDate = Date(timeIntervalSince1970: 1_000)

@Test func safetyPolicyAtBatteryThresholdEdgeAccepts59Minutes() throws {
    let policy = SafetyPolicy.standard

    let custom = SessionDuration(label: "59 Minutes", minutes: 59)
    try policy.validate(duration: custom, powerSource: .batteryPower)
}

@Test func safetyPolicyAtBatteryThresholdEdgeRejects60Minutes() {
    let policy = SafetyPolicy.standard

    #expect(throws: SafetyPolicyError.self) {
        try policy.validate(duration: .oneHour, powerSource: .batteryPower)
    }
}

@Test func safetyPolicyRejectsIndefinitelyOnBatteryByDefault() {
    let policy = SafetyPolicy.standard

    #expect(throws: SafetyPolicyError.self) {
        try policy.validate(duration: .indefinitely, powerSource: .batteryPower)
    }
}

@Test func safetyPolicyAcceptsIndefinitelyOnBatteryWhenExplicitlyAllowed() throws {
    let policy = SafetyPolicy(allowLongSessionsOnBattery: true)

    try policy.validate(duration: .indefinitely, powerSource: .batteryPower)
}

@Test func safetyPolicyEffectiveEndDateCapsIndefinitelyAtMaximum() {
    let policy = SafetyPolicy.standard

    let capped = policy.effectiveEndDate(for: .indefinitely, startedAt: startDate)
    #expect(capped == startDate.addingTimeInterval(TimeInterval(240 * 60)))
}

@Test func safetyPolicyEffectiveEndDatePreservesShortSession() {
    let policy = SafetyPolicy.standard

    let end = policy.effectiveEndDate(for: .thirtyMinutes, startedAt: startDate)
    #expect(end == startDate.addingTimeInterval(TimeInterval(30 * 60)))
}

@Test func safetyPolicyEffectiveEndDateCapsAtMaximumWhenRequestExceeds() {
    let policy = SafetyPolicy.standard

    let custom = SessionDuration(label: "10 Hours", minutes: 600)
    let end = policy.effectiveEndDate(for: custom, startedAt: startDate)
    #expect(end == startDate.addingTimeInterval(TimeInterval(240 * 60)))
}

@Test func safetyPolicyFormatMinutesBoundary() {
    #expect(SafetyPolicy.formatMinutes(0) == "0m")
    #expect(SafetyPolicy.formatMinutes(30) == "30m")
    #expect(SafetyPolicy.formatMinutes(59) == "59m")
    #expect(SafetyPolicy.formatMinutes(60) == "1h")
    #expect(SafetyPolicy.formatMinutes(61) == "61m")
    #expect(SafetyPolicy.formatMinutes(119) == "119m")
    #expect(SafetyPolicy.formatMinutes(120) == "2h")
    #expect(SafetyPolicy.formatMinutes(240) == "4h")
}

@Test func safetyPolicySessionNotesForAC() {
    let policy = SafetyPolicy.standard

    let notes = policy.sessionNotes(for: .oneHour, powerSource: .acPower)
    #expect(notes.contains("Power: AC Power"))
    #expect(!notes.contains(where: { $0.contains("battery") }))
}

@Test func safetyPolicySessionNotesForBatteryShortSession() throws {
    let policy = SafetyPolicy.standard

    let notes = policy.sessionNotes(for: .thirtyMinutes, powerSource: .batteryPower)
    #expect(notes.contains("Power: Battery"))
    #expect(!notes.contains(where: { $0.contains("Long battery") }))
}

@Test func safetyPolicySessionNotesForBatteryLongSessionBlocked() throws {
    let policy = SafetyPolicy.standard

    // Confirm the policy does reject this combo so the "blocked" note is meaningful.
    #expect(throws: SafetyPolicyError.self) {
        try policy.validate(duration: .oneHour, powerSource: .batteryPower)
    }

    let notes = policy.sessionNotes(for: .oneHour, powerSource: .batteryPower)
    #expect(notes.contains("Long battery blocked"))
}

@Test func safetyPolicySessionNotesForBatteryLongSessionAllowed() throws {
    let policy = SafetyPolicy(allowLongSessionsOnBattery: true)

    let notes = policy.sessionNotes(for: .oneHour, powerSource: .batteryPower)
    #expect(notes.contains("Long battery allowed"))
}

@Test func safetyPolicySessionNotesForIndefinitely() {
    let policy = SafetyPolicy.standard

    let notes = policy.sessionNotes(for: .indefinitely, powerSource: .acPower)
    #expect(notes.contains("Indefinite is capped"))
}

@Test func safetyPolicySessionNotesForDurationExceedingMaximum() {
    let policy = SafetyPolicy.standard
    let custom = SessionDuration(label: "10 Hours", minutes: 600)

    let notes = policy.sessionNotes(for: custom, powerSource: .acPower)
    #expect(notes.contains("Duration is capped"))
}

@Test func safetyPolicyCustomThresholdsAdjustBoundary() throws {
    let permissiveThreshold = SafetyPolicy(
        maximumSessionMinutes: 240,
        longSessionBatteryThresholdMinutes: 120,
        allowLongSessionsOnBattery: false
    )

    try permissiveThreshold.validate(duration: .oneHour, powerSource: .batteryPower)
    do {
        try permissiveThreshold.validate(
            duration: SessionDuration(label: "3 Hours", minutes: 180),
            powerSource: .batteryPower
        )
        Issue.record("3-hour battery session should be rejected at threshold 120")
    } catch let error as SafetyPolicyError {
        #expect(error == .longSessionOnBattery(durationLabel: "3 Hours", thresholdMinutes: 120))
    }
}
