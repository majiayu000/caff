import CaffCore
import Foundation
import Testing

private final class FakeIOPowerAssertionBackend: IOPowerAssertionBackend, @unchecked Sendable {
    var createStatuses: [IOReturn] = []
    var releaseStatuses: [IOReturn] = []

    var nextCreateStatus: IOReturn {
        get { createStatuses.first ?? kIOReturnSuccess }
        set { createStatuses = [newValue] }
    }

    var nextReleaseStatus: IOReturn {
        get { releaseStatuses.first ?? kIOReturnSuccess }
        set { releaseStatuses = [newValue] }
    }

    private(set) var createCallCount = 0
    private(set) var releaseCallCount = 0
    private(set) var lastCreateReason: String?
    private(set) var issuedIDs: [IOPMAssertionID] = []
    private(set) var releasedIDs: [IOPMAssertionID] = []

    private let lock = NSLock()
    private var nextIDCounter: UInt32 = 0xCAFE_0001

    func createAssertion(
        type: CFString,
        level: IOPMAssertionLevel,
        reason: CFString
    ) -> (status: IOReturn, id: IOPMAssertionID) {
        lock.lock()
        defer { lock.unlock() }

        createCallCount += 1
        lastCreateReason = reason as String
        let status = createStatuses.isEmpty ? kIOReturnSuccess : createStatuses.removeFirst()
        guard status == kIOReturnSuccess else {
            return (status, 0)
        }

        let id = IOPMAssertionID(nextIDCounter)
        nextIDCounter &+= 1
        issuedIDs.append(id)
        return (status, id)
    }

    func releaseAssertion(_ id: IOPMAssertionID) -> IOReturn {
        lock.lock()
        defer { lock.unlock() }

        releaseCallCount += 1
        releasedIDs.append(id)
        return releaseStatuses.isEmpty ? kIOReturnSuccess : releaseStatuses.removeFirst()
    }
}

private func makeOptions(
    duration: SessionDuration = .thirtyMinutes,
    keepDisplayAwake: Bool = false
) -> SessionOptions {
    SessionOptions(duration: duration, keepDisplayAwake: keepDisplayAwake)
}

@Test func fakeBackendCreateFailedSurfacesAsPowerAssertionError() {
    let backend = FakeIOPowerAssertionBackend()
    backend.nextCreateStatus = kIOReturnNoPower
    let controller = PowerAssertionController(backend: backend)

    #expect(throws: PowerAssertionError.self) {
        try controller.start(options: makeOptions())
    }
    #expect(backend.createCallCount == 1)
    #expect(!controller.isRunning)
}

@Test func fakeBackendDisplayCreateFailedAfterIdleSucceeds() {
    let backend = FakeIOPowerAssertionBackend()
    backend.createStatuses = [kIOReturnSuccess, kIOReturnNoPower]
    let controller = PowerAssertionController(backend: backend)

    #expect(throws: PowerAssertionError.self) {
        try controller.start(options: makeOptions(keepDisplayAwake: true))
    }
    #expect(backend.createCallCount == 2)
    #expect(backend.releaseCallCount == 1)
    #expect(!controller.isRunning)
}

@Test func fakeBackendCleanupAfterCreateFailedWrapsBothErrors() {
    let backend = FakeIOPowerAssertionBackend()
    backend.createStatuses = [kIOReturnSuccess, kIOReturnNoPower]
    backend.releaseStatuses = [kIOReturnNotResponding]
    let controller = PowerAssertionController(backend: backend)

    #expect(throws: PowerAssertionError.cleanupAfterCreateFailed(
        createFailure: "Failed to create displaySleep assertion: IOReturn \(kIOReturnNoPower)",
        cleanupFailure: "Failed to release idleSystemSleep assertion: IOReturn \(kIOReturnNotResponding)"
    )) {
        try controller.start(options: makeOptions(keepDisplayAwake: true))
    }
    #expect(backend.createCallCount == 2)
    #expect(backend.releaseCallCount == 1)
    #expect(controller.isRunning)
    #expect(controller.activeAssertions == [.idleSystemSleep])
}

@Test func fakeBackendReleaseFailedSurfacesAndRetainsAssertion() {
    let backend = FakeIOPowerAssertionBackend()
    let controller = PowerAssertionController(backend: backend)

    try? controller.start(options: makeOptions())
    #expect(controller.isRunning)

    backend.nextReleaseStatus = kIOReturnNotResponding
    #expect(throws: PowerAssertionError.self) {
        try controller.stop()
    }

    // Per the controller's documented behavior, a release failure leaves
    // the assertion retained.
    #expect(backend.releaseCallCount == 1)
    #expect(controller.isRunning)
    #expect(controller.activeAssertions == [.idleSystemSleep])
}

@Test func fakeBackendStartPassesReasonToBackend() throws {
    let backend = FakeIOPowerAssertionBackend()
    let controller = PowerAssertionController(backend: backend)

    let options = SessionOptions(
        duration: .thirtyMinutes,
        keepDisplayAwake: false,
        reason: "codex is active"
    )
    try controller.start(options: options)

    #expect(backend.lastCreateReason == "codex is active")
}

@Test func fakeBackendStartIsCountedOncePerAssertion() throws {
    let backend = FakeIOPowerAssertionBackend()
    let controller = PowerAssertionController(backend: backend)

    try controller.start(options: makeOptions(keepDisplayAwake: true))

    #expect(backend.createCallCount == 2)
    #expect(backend.issuedIDs.count == 2)
    #expect(backend.issuedIDs[0] != backend.issuedIDs[1])
}

@Test func fakeBackendStopReleasesAllAssertions() throws {
    let backend = FakeIOPowerAssertionBackend()
    let controller = PowerAssertionController(backend: backend)

    try controller.start(options: makeOptions(keepDisplayAwake: true))
    #expect(backend.releaseCallCount == 0)

    try controller.stop()
    #expect(backend.releaseCallCount == 2)
}
