import Foundation
import Testing
@testable import CaffCore

@Test func agentTouchKeepsAwakeUntilCooldownExpires() {
    let start = Date(timeIntervalSince1970: 10_000)
    let state = AgentActivityCooldown.touch(
        source: " codex ",
        cooldownSeconds: 1_800,
        now: start
    )

    let active = AgentActivityCooldown.evaluate(
        state: state,
        now: start.addingTimeInterval(60)
    )
    #expect(state.source == "codex")
    #expect(active.isKeepingAwake)
    #expect(active.cooldownUntil == start.addingTimeInterval(1_800))
    #expect(active.summary == "Agent activity: codex, sleep allowed in 29m")

    let expired = AgentActivityCooldown.evaluate(
        state: state,
        now: start.addingTimeInterval(1_801)
    )
    #expect(!expired.isKeepingAwake)
    #expect(expired.summary == "Agent activity idle")
}

@Test func laterTouchRefreshesCooldownWindow() {
    let start = Date(timeIntervalSince1970: 20_000)
    let refreshed = AgentActivityCooldown.touch(
        source: "claude",
        cooldownSeconds: 1_800,
        now: start.addingTimeInterval(1_700)
    )

    let evaluation = AgentActivityCooldown.evaluate(
        state: refreshed,
        now: start.addingTimeInterval(1_750)
    )
    #expect(evaluation.isKeepingAwake)
    #expect(evaluation.cooldownUntil == start.addingTimeInterval(3_500))
}

@Test func agentTouchReceiptKeepsLastReceivedSourceAndTime() {
    let receivedAt = Date(timeIntervalSince1970: 30_000)
    let state = AgentActivityCooldown.touch(
        source: " codex ",
        cooldownSeconds: 1_800,
        now: receivedAt
    )

    let receipt = AgentActivityTouch(state: state)

    #expect(receipt.source == "codex")
    #expect(receipt.receivedAt == receivedAt)
}
