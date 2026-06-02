import CaffCore
import Foundation
import Testing

private let startDate = Date(timeIntervalSince1970: 1_000)

@Test func sessionDurationPresetsAreInExpectedOrder() {
    #expect(SessionDuration.presets.map(\.label) == ["Indefinitely", "30 Minutes", "1 Hour", "4 Hours"])
}

@Test func sessionDurationIndefinitelyHasNilTimeInterval() {
    #expect(SessionDuration.indefinitely.minutes == nil)
    #expect(SessionDuration.indefinitely.timeInterval == nil)
    #expect(SessionDuration.indefinitely.endDate(from: startDate) == nil)
}

@Test func sessionDurationCustomMinutesProduceCorrectEndDate() {
    let custom = SessionDuration(label: "45 Minutes", minutes: 45)

    #expect(custom.endDate(from: startDate) == startDate.addingTimeInterval(TimeInterval(45 * 60)))
    #expect(custom.timeInterval == TimeInterval(45 * 60))
}

@Test func sessionDurationPresetThirtyMinutesEndDate() {
    #expect(SessionDuration.thirtyMinutes.endDate(from: startDate) == startDate.addingTimeInterval(30 * 60))
}

@Test func sessionDurationPresetFourHoursEndDate() {
    #expect(SessionDuration.fourHours.endDate(from: startDate) == startDate.addingTimeInterval(240 * 60))
}

@Test func remainingTimeFormatterNilEndDateIsOn() {
    #expect(RemainingTimeFormatter.compactRemaining(until: nil) == "on")
}

@Test func remainingTimeFormatterHoursAndMinutes() {
    let now = Date(timeIntervalSince1970: 0)
    let end = Date(timeIntervalSince1970: 2 * 3600 + 5 * 60)  // 2h 5m

    #expect(RemainingTimeFormatter.compactRemaining(now: now, until: end) == "2h 5m")
}

@Test func remainingTimeFormatterWholeHour() {
    let now = Date(timeIntervalSince1970: 0)
    let end = Date(timeIntervalSince1970: 2 * 3600)  // exactly 2h

    #expect(RemainingTimeFormatter.compactRemaining(now: now, until: end) == "2h")
}

@Test func remainingTimeFormatterWholeMinutes() {
    let now = Date(timeIntervalSince1970: 0)
    let end = Date(timeIntervalSince1970: 3 * 60)  // 3m exact

    #expect(RemainingTimeFormatter.compactRemaining(now: now, until: end) == "3m")
}

@Test func remainingTimeFormatterSubMinuteRoundsUp() {
    let now = Date(timeIntervalSince1970: 0)
    let end = Date(timeIntervalSince1970: 30)  // 30s

    #expect(RemainingTimeFormatter.compactRemaining(now: now, until: end) == "30s")
}

@Test func remainingTimeFormatterPastEndDateIsZero() {
    let now = Date(timeIntervalSince1970: 1_000)
    let past = Date(timeIntervalSince1970: 500)

    #expect(RemainingTimeFormatter.compactRemaining(now: now, until: past) == "0s")
}

@Test func remainingTimeFormatterDirectSecondsOverOneHour() {
    #expect(RemainingTimeFormatter.compactRemaining(untilSeconds: 3_700) == "1h 1m")
}

@Test func remainingTimeFormatterDirectSecondsUnderOneMinute() {
    #expect(RemainingTimeFormatter.compactRemaining(untilSeconds: 30) == "30s")
}
