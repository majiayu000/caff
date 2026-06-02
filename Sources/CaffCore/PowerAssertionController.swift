import Foundation
import IOKit.pwr_mgt

public enum PowerAssertionKind: String, CaseIterable, Sendable {
    case idleSystemSleep
    case displaySleep

    public var displayName: String {
        switch self {
        case .idleSystemSleep:
            return "PreventUserIdleSystemSleep"
        case .displaySleep:
            return "NoDisplaySleepAssertion"
        }
    }

    var sortOrder: Int {
        switch self {
        case .idleSystemSleep:
            return 0
        case .displaySleep:
            return 1
        }
    }

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
    case cleanupAfterCreateFailed(createFailure: String, cleanupFailure: String)

    public var description: String {
        switch self {
        case let .createFailed(kind, code):
            return "Failed to create \(kind.rawValue) assertion: IOReturn \(code)"
        case let .releaseFailed(kind, code):
            return "Failed to release \(kind.rawValue) assertion: IOReturn \(code)"
        case let .cleanupAfterCreateFailed(createFailure, cleanupFailure):
            return "\(createFailure); cleanup also failed: \(cleanupFailure)"
        }
    }
}

public final class PowerAssertionController {
    private var assertionIDs: [PowerAssertionKind: IOPMAssertionID] = [:]
    private let backend: IOPowerAssertionBackend

    public init(backend: IOPowerAssertionBackend = SystemIOPowerAssertionBackend()) {
        self.backend = backend
    }

    deinit {
        for (kind, assertionID) in assertionIDs {
            let result = backend.releaseAssertion(assertionID)
            if result != kIOReturnSuccess {
                Self.writeError("Caff failed to release \(kind.rawValue) assertion during cleanup: IOReturn \(result)")
            }
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
            let createFailure = error
            do {
                try stop()
            } catch {
                throw PowerAssertionError.cleanupAfterCreateFailed(
                    createFailure: String(describing: createFailure),
                    cleanupFailure: String(describing: error)
                )
            }
            throw createFailure
        }
    }

    public func stop() throws {
        var firstError: PowerAssertionError?
        var retainedAssertions: [PowerAssertionKind: IOPMAssertionID] = [:]

        for (kind, assertionID) in assertionIDs {
            let result = backend.releaseAssertion(assertionID)
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
        let result = backend.createAssertion(
            type: kind.assertionType,
            level: IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason: reason as CFString
        )

        guard result.status == kIOReturnSuccess else {
            throw PowerAssertionError.createFailed(kind: kind, code: result.status)
        }

        assertionIDs[kind] = result.id
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
