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
check(options.reason == "Caff is keeping this Mac awake", "default assertion reason should be stable")

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
