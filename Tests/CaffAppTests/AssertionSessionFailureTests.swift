import AppKit
import CaffCore
import IOKit.pwr_mgt
import Testing
@testable import caff

@Suite(.serialized)
@MainActor
struct AssertionSessionFailureTests {
    @Test
    func failedDisplayReleaseKeepsSessionAndStopAvailable() throws {
        let fixture = try AssertionSessionFixture()
        defer { fixture.cleanUp() }
        fixture.start()
        let original = try #require(fixture.app.activeSession)
        fixture.backend.releaseStatuses[.idleSystemSleep] = [kIOReturnNotResponding]

        fixture.app.toggleDisplayAwake()

        fixture.expectRunning([.idleSystemSleep], original: original)
        #expect(fixture.backend.createdKinds == [.idleSystemSleep])
        #expect(fixture.app.history.isEmpty)
        #expect(fixture.app.lastErrorMessage?.contains("Failed to release") == true)
        fixture.app.stopSession(result: .stopped)
        #expect(fixture.app.activeSession == nil)
        #expect(fixture.app.history.count == 1)
    }

    @Test
    func failedDisplayUpdateRestoresPreviousAssertionsAfterPartialRelease() throws {
        let fixture = try AssertionSessionFixture()
        defer { fixture.cleanUp() }
        fixture.start(displayAwake: true)
        let original = try #require(fixture.app.activeSession)
        fixture.backend.releaseStatuses[.displaySleep] = [kIOReturnNotResponding]

        fixture.app.toggleDisplayAwake()

        fixture.expectRunning([.idleSystemSleep, .displaySleep], original: original)
        #expect(fixture.backend.createdKinds == [.idleSystemSleep, .displaySleep, .idleSystemSleep, .displaySleep])
        #expect(fixture.app.history.isEmpty)
        #expect(fixture.app.lastErrorMessage?.contains("Failed to release displaySleep") == true)
    }

    @Test
    func failedDisplayCreationRestoresPreviousSessionWithoutChangingDeadline() throws {
        let fixture = try AssertionSessionFixture()
        defer { fixture.cleanUp() }
        fixture.start()
        let original = try #require(fixture.app.activeSession)
        fixture.backend.createStatuses = [kIOReturnSuccess, kIOReturnNoPower]

        fixture.app.toggleDisplayAwake()

        fixture.expectRunning([.idleSystemSleep], original: original)
        #expect(fixture.backend.createdKinds == [.idleSystemSleep, .idleSystemSleep, .displaySleep, .idleSystemSleep])
        #expect(fixture.app.history.isEmpty)
        #expect(fixture.app.lastErrorMessage?.contains("Failed to create displaySleep") == true)
    }

    @Test
    func failedRestorationReflectsRetainedAssertionsAndBothErrors() throws {
        let fixture = try AssertionSessionFixture()
        defer { fixture.cleanUp() }
        fixture.start(displayAwake: true)
        let original = try #require(fixture.app.activeSession)
        fixture.backend.createStatuses = [kIOReturnNoPower, kIOReturnSuccess, kIOReturnNoPower]
        fixture.backend.releaseStatuses[.idleSystemSleep] = [kIOReturnSuccess, kIOReturnNotResponding]

        fixture.app.toggleDisplayAwake()

        fixture.expectRunning([.idleSystemSleep], original: original)
        #expect(fixture.app.history.isEmpty)
        #expect(fixture.app.lastErrorMessage?.contains("Failed to create idleSystemSleep") == true)
        #expect(fixture.app.lastErrorMessage?.contains("restoring previous assertions also failed") == true)
        #expect(fixture.app.lastErrorMessage?.contains("cleanup also failed") == true)
        fixture.app.stopSession(result: .stopped)
        #expect(fixture.app.activeSession == nil)
        #expect(fixture.app.history.count == 1)
    }

    @Test
    func failedUpdateAndRestorationRecordsEndedSessionOnce() throws {
        let fixture = try AssertionSessionFixture()
        defer { fixture.cleanUp() }
        fixture.start(displayAwake: true)
        let original = try #require(fixture.app.activeSession)
        fixture.backend.createStatuses = [kIOReturnNoPower, kIOReturnNoPower]

        fixture.app.toggleDisplayAwake()

        #expect(!fixture.app.powerAssertions.isRunning)
        #expect(fixture.app.activeSession == nil)
        #expect(fixture.app.updateTimer == nil)
        #expect(!fixture.app.stopButton.isEnabled)
        #expect(fixture.app.history.count == 1)
        let entry = try #require(fixture.app.history.first)
        #expect(entry.result == .error)
        #expect(entry.startedAt == original.startedAt)
        #expect(entry.reason == original.reason)
        #expect(entry.assertionKinds == ["PreventUserIdleSystemSleep", "NoDisplaySleepAssertion"])
        #expect(entry.errorMessage?.contains("restoring previous assertions also failed") == true)
        #expect(fixture.app.statusStore.read()?.isRunning == false)
        fixture.app.stopSession(result: .stopped)
        #expect(fixture.app.history.count == 1)
    }

    @Test
    func failedStartCleanupLeavesTrackedSessionUntilStopSucceeds() throws {
        let fixture = try AssertionSessionFixture()
        defer { fixture.cleanUp() }
        fixture.app.keepDisplayAwake = true
        fixture.backend.createStatuses = [kIOReturnSuccess, kIOReturnNoPower]
        fixture.backend.releaseStatuses[.idleSystemSleep] = [kIOReturnNotResponding]

        #expect(!fixture.app.startSession(duration: .thirtyMinutes, source: .cli, reason: "failed start"))

        fixture.expectRunning([.idleSystemSleep])
        #expect(fixture.app.activeSession?.source == .cli)
        #expect(fixture.app.activeSession?.reason == "failed start")
        #expect(fixture.app.activeSession?.duration == .thirtyMinutes)
        #expect(fixture.app.lastErrorMessage?.contains("cleanup also failed") == true)
        #expect(fixture.app.history.isEmpty)
        fixture.app.stopSession(result: .stopped)
        #expect(fixture.app.activeSession == nil)
        #expect(fixture.app.history.count == 1)
        #expect(fixture.app.history.first?.reason == "failed start")
    }

    @Test
    func failedStartWithoutRetainedAssertionStaysOff() throws {
        let fixture = try AssertionSessionFixture()
        defer { fixture.cleanUp() }
        fixture.backend.createStatuses = [kIOReturnNoPower]

        #expect(!fixture.app.startSession(duration: .thirtyMinutes))

        #expect(fixture.app.activeSession == nil)
        #expect(!fixture.app.powerAssertions.isRunning)
        #expect(fixture.app.updateTimer == nil)
        #expect(fixture.app.history.isEmpty)
        #expect(fixture.app.lastErrorMessage?.contains("Failed to create") == true)
    }

    @Test
    func failedRestartReleaseKeepsOriginalSessionMetadata() throws {
        let fixture = try AssertionSessionFixture()
        defer { fixture.cleanUp() }
        fixture.start(displayAwake: true)
        let original = try #require(fixture.app.activeSession)
        fixture.backend.releaseStatuses[.displaySleep] = [kIOReturnNotResponding]

        #expect(!fixture.app.startSession(duration: .oneHour, source: .agent, reason: "replacement"))

        fixture.expectRunning([.displaySleep], original: original)
        #expect(fixture.backend.createdKinds == [.idleSystemSleep, .displaySleep])
        #expect(fixture.app.history.isEmpty)
    }

    @Test
    func policyRefusalDoesNotReplaceAnExistingSession() throws {
        let fixture = try AssertionSessionFixture()
        defer { fixture.cleanUp() }
        fixture.start(displayAwake: true)
        let original = try #require(fixture.app.activeSession)
        fixture.powerSource = .batteryPower

        #expect(!fixture.app.startSession(duration: .oneHour, source: .agent, reason: "refused replacement"))

        fixture.expectRunning([.idleSystemSleep, .displaySleep], original: original)
        #expect(fixture.backend.createdKinds == [.idleSystemSleep, .displaySleep])
        #expect(fixture.app.history.isEmpty)
        #expect(fixture.app.lastErrorMessage?.contains("sessions require AC power") == true)
    }

    @Test
    func failedReplacementCleanupTracksNewAssertionsAndRecordsOldSession() throws {
        let fixture = try AssertionSessionFixture()
        defer { fixture.cleanUp() }
        fixture.start()
        let original = try #require(fixture.app.activeSession)
        fixture.app.keepDisplayAwake = true
        fixture.backend.createStatuses = [kIOReturnSuccess, kIOReturnNoPower]
        fixture.backend.releaseStatuses[.idleSystemSleep] = [kIOReturnSuccess, kIOReturnNotResponding]

        #expect(!fixture.app.startSession(duration: .oneHour, source: .agent, reason: "replacement"))

        fixture.expectRunning([.idleSystemSleep])
        #expect(fixture.app.activeSession?.reason == "replacement")
        #expect(fixture.app.activeSession?.source == .agent)
        #expect(fixture.app.activeSession?.duration == .oneHour)
        #expect(fixture.app.history.count == 1)
        #expect(fixture.app.history.first?.startedAt == original.startedAt)
        #expect(fixture.app.history.first?.reason == original.reason)
        #expect(fixture.app.history.first?.result == .error)
        fixture.app.stopSession(result: .stopped)
        #expect(fixture.app.history.count == 2)
        #expect(fixture.app.history.first?.reason == "replacement")
    }

    @Test
    func failedStopReflectsPartialReleaseAndCanRetry() throws {
        let fixture = try AssertionSessionFixture()
        defer { fixture.cleanUp() }
        fixture.start(displayAwake: true)
        let original = try #require(fixture.app.activeSession)
        fixture.backend.releaseStatuses[.idleSystemSleep] = [kIOReturnNotResponding]

        fixture.app.stopSession(result: .stopped)

        fixture.expectRunning([.idleSystemSleep], original: original)
        #expect(fixture.app.history.isEmpty)
        fixture.app.stopSession(result: .stopped)
        #expect(!fixture.app.powerAssertions.isRunning)
        #expect(fixture.app.activeSession == nil)
        #expect(fixture.app.updateTimer == nil)
        #expect(fixture.app.history.count == 1)
        #expect(fixture.app.history.first?.result == .stopped)
    }

    @Test
    func failedPolicyStopReflectsRetainedAssertions() throws {
        let fixture = try AssertionSessionFixture()
        defer { fixture.cleanUp() }
        fixture.start(displayAwake: true, duration: .oneHour)
        let original = try #require(fixture.app.activeSession)
        fixture.backend.releaseStatuses[.idleSystemSleep] = [kIOReturnNotResponding]
        fixture.powerSource = .batteryPower

        fixture.app.tick()

        fixture.expectRunning([.idleSystemSleep], original: original)
        #expect(fixture.app.history.isEmpty)
        #expect(fixture.app.lastErrorMessage?.contains("Failed to release") == true)
    }

    @Test
    func successfulDisplayTogglePreservesMetadataAndDeadline() throws {
        let fixture = try AssertionSessionFixture()
        defer { fixture.cleanUp() }
        fixture.start()
        let original = try #require(fixture.app.activeSession)

        fixture.app.toggleDisplayAwake()
        fixture.expectRunning([.idleSystemSleep, .displaySleep], original: original)
        fixture.app.toggleDisplayAwake()
        fixture.expectRunning([.idleSystemSleep], original: original)
        #expect(fixture.app.lastErrorMessage == nil)
        #expect(fixture.app.history.isEmpty)
    }
}

@MainActor
private final class AssertionSessionFixture {
    let backend = SessionFailureBackend()
    let directory: URL
    var powerSource = PowerSourceState.acPower
    var app: AppDelegate!

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        app = AppDelegate(
            powerAssertions: PowerAssertionController(backend: backend),
            currentPowerSource: { [unowned self] in self.powerSource },
            historyStore: SessionHistoryStore(fileURL: directory.appendingPathComponent("history.json")),
            statusStore: CaffStatusStore(fileURL: directory.appendingPathComponent("status.json"))
        )
        app.presentsErrorsRemotely = true
    }

    func start(displayAwake: Bool = false, duration: SessionDuration = .thirtyMinutes) {
        app.keepDisplayAwake = displayAwake
        #expect(app.startSession(duration: duration, source: .cli, reason: "original session"))
    }

    func expectRunning(_ assertions: Set<PowerAssertionKind>, original: WakeSession? = nil) {
        #expect(app.powerAssertions.activeAssertions == assertions)
        #expect(app.activeSession?.activeAssertions == assertions)
        #expect(app.activeSession?.keepDisplayAwake == assertions.contains(.displaySleep))
        #expect(app.keepDisplayAwake == assertions.contains(.displaySleep))
        #expect(app.updateTimer?.isValid == true)
        #expect(app.stopButton.isEnabled)
        #expect(app.heroActionButton.title == app.text.stop)
        #expect(app.statusItem.menu?.items.contains { $0.action == #selector(AppDelegate.stopSessionFromMenu) } == true)
        #expect(app.statusStore.read()?.isRunning == true)
        #expect(app.statusStore.read()?.assertions == app.activeSession?.assertionSummary)
        if let original {
            #expect(app.activeSession?.startedAt == original.startedAt)
            #expect(app.activeSession?.endDate == original.endDate)
            #expect(app.activeSession?.reason == original.reason)
            #expect(app.activeSession?.source == original.source)
            #expect(app.activeSession?.duration == original.duration)
        }
    }

    func cleanUp() {
        app.updateTimer?.invalidate()
        app.agentActivityTimer?.invalidate()
        backend.releaseStatuses = [:]
        do { try app.powerAssertions.stop() } catch { Issue.record(error) }
        NSStatusBar.system.removeStatusItem(app.statusItem)
        do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
    }
}

private final class SessionFailureBackend: IOPowerAssertionBackend, @unchecked Sendable {
    var createStatuses: [IOReturn] = []
    var releaseStatuses: [PowerAssertionKind: [IOReturn]] = [:]
    private(set) var createdKinds: [PowerAssertionKind] = []
    private var kindsByID: [IOPMAssertionID: PowerAssertionKind] = [:]
    private var nextID: IOPMAssertionID = 1

    func createAssertion(type: CFString, level: IOPMAssertionLevel, reason: CFString) -> (status: IOReturn, id: IOPMAssertionID) {
        let kind: PowerAssertionKind = (type as String) == (kIOPMAssertionTypeNoDisplaySleep as String) ? .displaySleep : .idleSystemSleep
        createdKinds.append(kind)
        let status = createStatuses.isEmpty ? kIOReturnSuccess : createStatuses.removeFirst()
        guard status == kIOReturnSuccess else { return (status, 0) }
        let id = nextID
        nextID += 1
        kindsByID[id] = kind
        return (status, id)
    }

    func releaseAssertion(_ id: IOPMAssertionID) -> IOReturn {
        guard let kind = kindsByID[id] else { return kIOReturnBadArgument }
        var statuses = releaseStatuses[kind] ?? []
        let status = statuses.isEmpty ? kIOReturnSuccess : statuses.removeFirst()
        releaseStatuses[kind] = statuses
        if status == kIOReturnSuccess { kindsByID.removeValue(forKey: id) }
        return status
    }
}
