import AppKit
import CaffCore
import IOKit.pwr_mgt
import Testing
@testable import caff

@Suite(.serialized)
@MainActor
struct RemoteCommandResultTests {
    @Test(arguments: [nil, "60"] as [String?])
    func remoteStartReturnsFalseWhenBatteryPolicyRefuses(minutes: String?) throws {
        let fixture = try RemoteCommandFixture(powerSource: .batteryPower)
        defer { fixture.cleanUp() }
        var command = ["action": "start", "displayAwake": "true"]
        command["minutes"] = minutes

        #expect(!fixture.app.acceptSignedRemoteCommand(command))
        #expect(fixture.app.activeSession == nil)
        #expect(!fixture.app.keepDisplayAwake)
        #expect(fixture.backend.createdTypes.isEmpty)
        #expect(fixture.app.lastErrorMessage?.contains("sessions require AC power") == true)
        #expect(fixture.app.statusStore.read()?.isRunning == false)

        fixture.app.withRemoteErrorPresentation {
            #expect(fixture.app.startSession(duration: .thirtyMinutes))
        }
        #expect(fixture.app.activeSession?.keepDisplayAwake == false)
        #expect(fixture.app.powerAssertions.activeAssertions == [.idleSystemSleep])
    }

    @Test(arguments: [false, true])
    func remoteStartReturnsFalseWhenAssertionCreationFails(displayAwake: Bool) throws {
        let fixture = try RemoteCommandFixture()
        defer { fixture.cleanUp() }
        fixture.app.keepDisplayAwake = !displayAwake
        fixture.backend.createStatus = kIOReturnNoPower

        #expect(!fixture.app.acceptSignedRemoteCommand([
            "action": "start", "minutes": "30", "displayAwake": String(displayAwake)
        ]))
        #expect(fixture.app.activeSession == nil)
        #expect(fixture.app.keepDisplayAwake == !displayAwake)
        #expect(fixture.app.lastErrorMessage?.contains("Failed to create") == true)
    }

    @Test(arguments: [false, true])
    func remoteStartReturnsTrueAndAppliesDisplayChoice(displayAwake: Bool) throws {
        let fixture = try RemoteCommandFixture()
        defer { fixture.cleanUp() }
        fixture.app.keepDisplayAwake = !displayAwake

        #expect(fixture.app.acceptSignedRemoteCommand([
            "action": "start", "minutes": "30", "displayAwake": String(displayAwake)
        ]))
        #expect(fixture.app.activeSession?.keepDisplayAwake == displayAwake)
        #expect(fixture.app.keepDisplayAwake == displayAwake)
        #expect(fixture.app.powerAssertions.activeAssertions == (
            displayAwake ? [.idleSystemSleep, .displaySleep] : [.idleSystemSleep]
        ))
        #expect(fixture.app.lastErrorMessage == nil)
        #expect(fixture.app.statusStore.read()?.keepDisplayAwake == displayAwake)
    }

    @Test
    func remoteStopReturnsFalseAndRetainsSessionUntilReleaseSucceeds() throws {
        let fixture = try RemoteCommandFixture()
        defer { fixture.cleanUp() }
        #expect(fixture.app.acceptSignedRemoteCommand(["action": "start", "minutes": "30"]))
        let session = try #require(fixture.app.activeSession)
        fixture.backend.releaseStatus = kIOReturnNotResponding

        #expect(!fixture.app.acceptSignedRemoteCommand(["action": "stop"]))
        #expect(fixture.app.activeSession == session.updatingAssertions(
            session.activeAssertions,
            keepDisplayAwake: session.keepDisplayAwake,
            errorMessage: fixture.app.lastErrorMessage
        ))
        #expect(fixture.app.powerAssertions.isRunning)
        #expect(fixture.app.history.isEmpty)
        #expect(fixture.app.lastErrorMessage?.contains("Failed to release") == true)
        #expect(fixture.app.statusStore.read()?.isRunning == true)

        fixture.backend.releaseStatus = kIOReturnSuccess
        #expect(fixture.app.acceptSignedRemoteCommand(["action": "stop"]))
        #expect(fixture.app.activeSession == nil)
        #expect(!fixture.app.powerAssertions.isRunning)
        #expect(fixture.app.history.count == 1)
        #expect(fixture.app.lastErrorMessage == nil)
        #expect(fixture.app.acceptSignedRemoteCommand(["action": "stop"]))
        #expect(fixture.app.history.count == 1)
    }

    @Test
    func remoteAgentTouchReturnsFalseWhenBatteryPolicyRefuses() throws {
        let fixture = try RemoteCommandFixture(powerSource: .batteryPower)
        defer { fixture.cleanUp() }

        #expect(!fixture.app.acceptSignedRemoteCommand([
            "action": "agent-touch", "source": "codex", "cooldownSeconds": "3600"
        ]))
        #expect(fixture.app.activeSession == nil)
        #expect(fixture.app.agentActivityState == nil)
        #expect(fixture.app.agentActivityTimer == nil)
        #expect(fixture.app.lastErrorMessage?.contains("sessions require AC power") == true)
    }

    @Test
    func remoteAgentTouchReturnsFalseWhenAssertionCreationFails() throws {
        let fixture = try RemoteCommandFixture()
        defer { fixture.cleanUp() }
        fixture.backend.createStatus = kIOReturnNoPower

        #expect(!fixture.app.acceptSignedRemoteCommand(["action": "agent-touch", "source": "codex"]))
        #expect(fixture.app.activeSession == nil)
        #expect(fixture.app.agentActivityState == nil)
        #expect(fixture.app.lastErrorMessage?.contains("Failed to create") == true)
    }

    @Test
    func remoteAgentTouchReturnsFalseWhenAssertionRefreshFails() throws {
        let fixture = try RemoteCommandFixture()
        defer { fixture.cleanUp() }
        #expect(fixture.app.acceptSignedRemoteCommand(["action": "agent-touch", "source": "codex"]))
        try fixture.app.powerAssertions.stop()
        fixture.backend.createStatus = kIOReturnNoPower

        #expect(!fixture.app.acceptSignedRemoteCommand(["action": "agent-touch", "source": "codex"]))
        #expect(fixture.app.agentActivityState == nil)
        #expect(fixture.app.lastErrorMessage?.contains("Failed to create") == true)
    }

    @Test
    func remoteAgentTouchReturnsTrueForNewAndExistingSessions() throws {
        let fixture = try RemoteCommandFixture()
        defer { fixture.cleanUp() }
        #expect(fixture.app.acceptSignedRemoteCommand(["action": "agent-touch", "source": "codex"]))
        #expect(fixture.app.activeSession?.source == .agent)
        #expect(fixture.app.agentActivityState?.source == "codex")
        #expect(fixture.app.acceptSignedRemoteCommand(["action": "agent-touch", "source": "claude"]))
        #expect(fixture.app.agentActivityState?.source == "claude")
        #expect(fixture.app.lastErrorMessage == nil)
    }

    @Test
    func remoteStartReturnsFalseWithoutChangingAnExistingSession() throws {
        let fixture = try RemoteCommandFixture()
        defer { fixture.cleanUp() }
        #expect(fixture.app.acceptSignedRemoteCommand(["action": "start", "minutes": "30"]))
        let session = try #require(fixture.app.activeSession)

        #expect(!fixture.app.acceptSignedRemoteCommand([
            "action": "start", "minutes": "30", "displayAwake": "true"
        ]))
        #expect(fixture.app.activeSession == session)
        #expect(!fixture.app.keepDisplayAwake)
        #expect(fixture.app.lastErrorMessage?.contains("already running") == true)
    }
}

@MainActor
private struct RemoteCommandFixture {
    let directory: URL
    let backend = RemoteCommandAssertionBackend()
    let app: AppDelegate

    init(powerSource: PowerSourceState = .acPower) throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteCommandResult-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app = AppDelegate(
            powerAssertions: PowerAssertionController(backend: backend),
            currentPowerSource: { powerSource },
            historyStore: SessionHistoryStore(fileURL: directory.appendingPathComponent("history.json")),
            statusStore: CaffStatusStore(fileURL: directory.appendingPathComponent("status.json"))
        )
    }

    func cleanUp() {
        app.updateTimer?.invalidate()
        app.cancelAgentActivityCooldown()
        backend.releaseStatus = kIOReturnSuccess
        do {
            try app.powerAssertions.stop()
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Remote command fixture cleanup failed: \(error)")
        }
        NSStatusBar.system.removeStatusItem(app.statusItem)
    }
}

private final class RemoteCommandAssertionBackend: IOPowerAssertionBackend, @unchecked Sendable {
    var createStatus = kIOReturnSuccess
    var releaseStatus = kIOReturnSuccess
    var createdTypes: [String] = []

    func createAssertion(
        type: CFString,
        level: IOPMAssertionLevel,
        reason: CFString
    ) -> (status: IOReturn, id: IOPMAssertionID) {
        createdTypes.append(type as String)
        return (createStatus, IOPMAssertionID(createdTypes.count))
    }

    func releaseAssertion(_ id: IOPMAssertionID) -> IOReturn {
        releaseStatus
    }
}
