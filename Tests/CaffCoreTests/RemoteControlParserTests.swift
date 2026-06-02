import CaffCore
import Foundation
import Testing

// MARK: - duration(minutes:)

@Test func remoteControlDurationNilIsIndefinitely() throws {
    #expect(try RemoteControlParser.duration(minutes: nil) == .indefinitely)
}

@Test func remoteControlDurationEmptyStringIsIndefinitely() throws {
    #expect(try RemoteControlParser.duration(minutes: "") == .indefinitely)
}

@Test func remoteControlDurationParsesPositiveInteger() throws {
    let parsed = try RemoteControlParser.duration(minutes: "45")
    #expect(parsed.minutes == 45)
    #expect(parsed.label == "45 Minutes")
}

@Test func remoteControlDurationParsesVeryLargeValue() throws {
    let parsed = try RemoteControlParser.duration(minutes: "99999")
    #expect(parsed.minutes == 99999)
}

@Test func remoteControlDurationRejectsZero() {
    #expect(throws: RemoteControlError.self) {
        _ = try RemoteControlParser.duration(minutes: "0")
    }
}

@Test func remoteControlDurationRejectsNegative() {
    #expect(throws: RemoteControlError.self) {
        _ = try RemoteControlParser.duration(minutes: "-5")
    }
}

@Test func remoteControlDurationRejectsNonNumeric() {
    #expect(throws: RemoteControlError.self) {
        _ = try RemoteControlParser.duration(minutes: "abc")
    }
}

@Test func remoteControlDurationErrorContainsOriginalValue() {
    let error = #expect(throws: RemoteControlError.self) {
        _ = try RemoteControlParser.duration(minutes: "garbage")
    }
    #expect(error == .invalidDuration("garbage"))
    #expect(String(describing: error).contains("garbage"))
}

// MARK: - source(_:)

@Test func remoteControlSourceNilIsCLI() throws {
    #expect(try RemoteControlParser.source(nil) == .cli)
}

@Test func remoteControlSourceEmptyStringIsCLI() throws {
    #expect(try RemoteControlParser.source("") == .cli)
}

@Test func remoteControlSourceAcceptsAllValidValues() throws {
    #expect(try RemoteControlParser.source("manual") == .manual)
    #expect(try RemoteControlParser.source("agent") == .agent)
    #expect(try RemoteControlParser.source("cli") == .cli)
    #expect(try RemoteControlParser.source("url") == .url)
}

@Test func remoteControlSourceIsCaseSensitive() {
    #expect(throws: RemoteControlError.self) {
        _ = try RemoteControlParser.source("Manual")
    }
}

@Test func remoteControlSourceRejectsRemovedValues() {
    for removed in ["process", "workspace"] {
        #expect(throws: RemoteControlError.self) {
            _ = try RemoteControlParser.source(removed)
        }
    }
}

@Test func remoteControlSourceErrorContainsOriginalValue() {
    let error = #expect(throws: RemoteControlError.self) {
        _ = try RemoteControlParser.source("process")
    }
    #expect(error == .invalidSource("process"))
}

// MARK: - cooldownSeconds(_:)

@Test func remoteControlCooldownNilIsDefault() throws {
    #expect(try RemoteControlParser.cooldownSeconds(nil) == 1_800)
}

@Test func remoteControlCooldownEmptyStringIsDefault() throws {
    #expect(try RemoteControlParser.cooldownSeconds("") == 1_800)
}

@Test func remoteControlCooldownParsesPositiveInteger() throws {
    #expect(try RemoteControlParser.cooldownSeconds("60") == 60)
    #expect(try RemoteControlParser.cooldownSeconds("1800") == 1_800)
}

@Test func remoteControlCooldownRejectsZero() {
    #expect(throws: RemoteControlError.self) {
        _ = try RemoteControlParser.cooldownSeconds("0")
    }
}

@Test func remoteControlCooldownRejectsNegative() {
    #expect(throws: RemoteControlError.self) {
        _ = try RemoteControlParser.cooldownSeconds("-1")
    }
}

@Test func remoteControlCooldownRejectsNonNumeric() {
    #expect(throws: RemoteControlError.self) {
        _ = try RemoteControlParser.cooldownSeconds("abc")
    }
}

// MARK: - bool(_:)

@Test func remoteControlBoolNilIsFalse() {
    #expect(!RemoteControlParser.bool(nil))
}

@Test func remoteControlBoolTrueVariants() {
    for value in ["1", "true", "yes", "on"] {
        #expect(RemoteControlParser.bool(value), "expected \(value) to be truthy")
    }
}

@Test func remoteControlBoolIsCaseInsensitive() {
    for value in ["TRUE", "True", "YES", "Yes", "ON", "On"] {
        #expect(RemoteControlParser.bool(value), "expected \(value) to be truthy")
    }
}

@Test func remoteControlBoolFalseVariants() {
    for value in ["0", "false", "no", "off", "garbage", ""] {
        #expect(!RemoteControlParser.bool(value), "expected \(value) to be falsy")
    }
}
