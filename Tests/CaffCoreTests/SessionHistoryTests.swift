import CaffCore
import Foundation
import Testing

private let referenceDate = Date(timeIntervalSince1970: 1_000)

private func makeSession(
    source: SessionSource = .manual,
    duration: SessionDuration = .oneHour,
    activeAssertions: Set<PowerAssertionKind> = [.idleSystemSleep]
) -> WakeSession {
    WakeSession(
        options: SessionOptions(
            duration: duration,
            source: source,
            keepDisplayAwake: activeAssertions.contains(.displaySleep),
            reason: "test reason"
        ),
        startedAt: referenceDate,
        activeAssertions: activeAssertions
    )
}

@Test func sessionHistoryEntryRoundTripsThroughJSON() throws {
    let session = makeSession(
        source: .agent,
        duration: .fourHours,
        activeAssertions: [.idleSystemSleep, .displaySleep]
    )

    let entry = SessionHistoryEntry(
        session: session,
        endedAt: referenceDate.addingTimeInterval(60),
        result: .timedOut
    )

    let encoded = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(SessionHistoryEntry.self, from: encoded)

    #expect(decoded == entry)
    #expect(decoded.result == .timedOut)
    #expect(decoded.assertionKinds == ["PreventUserIdleSystemSleep", "NoDisplaySleepAssertion"])
    #expect(decoded.summary == "Timed Out: Agent - 4 Hours")
}

@Test func sessionHistoryDecodesLegacyExitedResultAsStopped() throws {
    let legacyData = Data("""
    {
      "id": "00000000-0000-0000-0000-000000000001",
      "startedAt": 1000,
      "endedAt": 1120,
      "source": "Manual",
      "reason": "test",
      "durationLabel": "1 Hour",
      "assertionKinds": ["PreventUserIdleSystemSleep"],
      "result": "exited"
    }
    """.utf8)

    let entry = try JSONDecoder().decode(SessionHistoryEntry.self, from: legacyData)
    #expect(entry.result == .stopped)
}

@Test func sessionHistoryRejectsUnknownResult() {
    let data = Data("""
    {
      "id": "00000000-0000-0000-0000-000000000001",
      "startedAt": 1000,
      "endedAt": 1120,
      "source": "Manual",
      "reason": "test",
      "durationLabel": "1 Hour",
      "assertionKinds": ["PreventUserIdleSystemSleep"],
      "result": "exploded"
    }
    """.utf8)

    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(SessionHistoryEntry.self, from: data)
    }
}

@Test func sessionHistoryResultEncodingRoundTripsForAllCases() throws {
    for result in [SessionHistoryResult.stopped, .timedOut, .policyStopped, .error] {
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SessionHistoryResult.self, from: data)
        #expect(decoded == result)
    }
}

@Test func sessionHistoryEntryFromSessionPreservesAssertionOrder() {
    let session = makeSession(activeAssertions: [.displaySleep, .idleSystemSleep])

    let entry = SessionHistoryEntry(
        session: session,
        endedAt: referenceDate,
        result: .stopped
    )

    // PowerAssertionKind.sortOrder puts idleSystemSleep (0) before displaySleep (1).
    #expect(entry.assertionKinds == ["PreventUserIdleSystemSleep", "NoDisplaySleepAssertion"])
}

@Test func sessionHistoryEntryIncludesErrorMessageWhenPresent() {
    let session = makeSession()

    let entry = SessionHistoryEntry(
        session: session,
        endedAt: referenceDate,
        result: .error,
        errorMessage: "boom"
    )

    #expect(entry.errorMessage == "boom")
    #expect(entry.result == .error)
}
