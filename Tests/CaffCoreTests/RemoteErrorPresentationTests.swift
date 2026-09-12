import CaffCore
import Foundation
import Testing

@Test func remoteErrorPresentationAllowsFirstNotification() {
    var presentation = RemoteErrorPresentation(minimumInterval: 5)
    let now = Date(timeIntervalSince1970: 1_000)

    let allowed = presentation.shouldEmitNotification(now: now)
    #expect(allowed)
    #expect(presentation.lastNotificationAt == now)
}

@Test func remoteErrorPresentationRateLimitsWithinInterval() {
    var presentation = RemoteErrorPresentation(minimumInterval: 5)
    let start = Date(timeIntervalSince1970: 2_000)

    let first = presentation.shouldEmitNotification(now: start)
    let second = presentation.shouldEmitNotification(now: start.addingTimeInterval(1))
    let third = presentation.shouldEmitNotification(now: start.addingTimeInterval(4.999))

    #expect(first)
    #expect(!second)
    #expect(!third)
    #expect(presentation.lastNotificationAt == start)
}

@Test func remoteErrorPresentationAllowsNotificationAfterInterval() {
    var presentation = RemoteErrorPresentation(minimumInterval: 5)
    let start = Date(timeIntervalSince1970: 3_000)

    let first = presentation.shouldEmitNotification(now: start)
    let next = start.addingTimeInterval(5)
    let second = presentation.shouldEmitNotification(now: next)

    #expect(first)
    #expect(second)
    #expect(presentation.lastNotificationAt == next)
}

@Test func remoteErrorPresentationUsesDefaultFiveSecondInterval() {
    #expect(RemoteErrorPresentation.defaultMinimumInterval == 5)
    let presentation = RemoteErrorPresentation()
    #expect(presentation.minimumInterval == 5)
    #expect(presentation.lastNotificationAt == nil)
}
