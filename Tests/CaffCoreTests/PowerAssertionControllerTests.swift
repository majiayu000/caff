import CaffCore
import Foundation
import Testing

@Test func powerAssertionStartWithoutDisplaySleepOnlyAcquiresIdleAssertion() throws {
    let controller = PowerAssertionController()

    try controller.start(options: SessionOptions(duration: .thirtyMinutes, keepDisplayAwake: false))

    #expect(controller.isRunning)
    #expect(controller.activeAssertions == [.idleSystemSleep])
}

@Test func powerAssertionStartWithDisplaySleepAcquiresBothAssertions() throws {
    let controller = PowerAssertionController()

    try controller.start(options: SessionOptions(duration: .oneHour, keepDisplayAwake: true))

    #expect(controller.activeAssertions == [.idleSystemSleep, .displaySleep])
}

@Test func powerAssertionIsIdempotentAcrossRepeatedStarts() throws {
    let controller = PowerAssertionController()

    try controller.start(options: SessionOptions(duration: .thirtyMinutes))
    try controller.start(options: SessionOptions(duration: .fourHours, keepDisplayAwake: true))

    #expect(controller.activeAssertions == [.idleSystemSleep, .displaySleep])
    #expect(controller.isRunning)

    try controller.stop()
    #expect(!controller.isRunning)
}

@Test func powerAssertionStopIsIdempotent() throws {
    let controller = PowerAssertionController()

    try controller.start(options: SessionOptions(duration: .thirtyMinutes))
    try controller.stop()
    try controller.stop()

    #expect(!controller.isRunning)
    #expect(controller.activeAssertions.isEmpty)
}

@Test func powerAssertionAssertionsAppearInStableSortOrder() throws {
    let controller = PowerAssertionController()

    try controller.start(options: SessionOptions(duration: .thirtyMinutes, keepDisplayAwake: true))

    // Both assertions should be present; their assertionSummary ordering is verified in
    // WakeSession tests, but we also want the controller's set to include both.
    #expect(controller.activeAssertions.contains(.idleSystemSleep))
    #expect(controller.activeAssertions.contains(.displaySleep))
}

@Test func powerAssertionInactiveStateHasEmptyActiveAssertions() {
    let controller = PowerAssertionController()

    #expect(!controller.isRunning)
    #expect(controller.activeAssertions.isEmpty)
}
