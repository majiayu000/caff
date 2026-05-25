import Foundation
import IOKit.pwr_mgt

public enum PowerAssertionKind: String, CaseIterable, Sendable {
    case idleSystemSleep
    case displaySleep

    var assertionType: CFString {
        switch self {
        case .idleSystemSleep:
            return kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
        case .displaySleep:
            return kIOPMAssertionTypeNoDisplaySleep as CFString
        }
    }
}

public enum PowerAssertionError: Error, CustomStringConvertible, Equatable {
    case createFailed(kind: PowerAssertionKind, code: IOReturn)
    case releaseFailed(kind: PowerAssertionKind, code: IOReturn)

    public var description: String {
        switch self {
        case let .createFailed(kind, code):
            return "Failed to create \(kind.rawValue) assertion: IOReturn \(code)"
        case let .releaseFailed(kind, code):
            return "Failed to release \(kind.rawValue) assertion: IOReturn \(code)"
        }
    }
}

public final class PowerAssertionController {
    private var assertionIDs: [PowerAssertionKind: IOPMAssertionID] = [:]

    public init() {}

    deinit {
        for assertionID in assertionIDs.values {
            _ = IOPMAssertionRelease(assertionID)
        }
    }

    public var isRunning: Bool {
        !assertionIDs.isEmpty
    }

    public var activeAssertions: Set<PowerAssertionKind> {
        Set(assertionIDs.keys)
    }

    public func start(options: SessionOptions) throws {
        try stop()

        do {
            try createAssertion(.idleSystemSleep, reason: options.reason)

            if options.keepDisplayAwake {
                try createAssertion(.displaySleep, reason: options.reason)
            }
        } catch {
            try? stop()
            throw error
        }
    }

    public func stop() throws {
        var firstError: PowerAssertionError?
        var retainedAssertions: [PowerAssertionKind: IOPMAssertionID] = [:]

        for (kind, assertionID) in assertionIDs {
            let result = IOPMAssertionRelease(assertionID)
            if result != kIOReturnSuccess, firstError == nil {
                firstError = .releaseFailed(kind: kind, code: result)
            }
            if result != kIOReturnSuccess {
                retainedAssertions[kind] = assertionID
            }
        }

        assertionIDs = retainedAssertions

        if let firstError {
            throw firstError
        }
    }

    private func createAssertion(_ kind: PowerAssertionKind, reason: String) throws {
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kind.assertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )

        guard result == kIOReturnSuccess else {
            throw PowerAssertionError.createFailed(kind: kind, code: result)
        }

        assertionIDs[kind] = assertionID
    }
}
