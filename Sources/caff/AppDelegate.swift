import AppKit
import CaffCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let powerAssertions = PowerAssertionController()
    let windowStatusLabel = NSTextField(labelWithString: "Off")
    let heroEyebrowLabel = NSTextField(labelWithString: "READY - STANDBY")
    let heroTitleLabel = NSTextField(labelWithString: "Ready to keep awake")
    let heroMetaLabel = NSTextField(labelWithString: "No active power assertion")
    let heroStatusDot = NSView()
    let heroActionButton = NSButton(title: "Start", target: nil, action: nil)
    let sourceProofLabel = NSTextField(labelWithString: "Source: None")
    let assertionProofLabel = NSTextField(labelWithString: "Assertions: None")
    let reasonProofLabel = NSTextField(labelWithString: "Reason: None")
    let startedProofLabel = NSTextField(labelWithString: "Started: None")
    let errorProofLabel = NSTextField(labelWithString: "")
    let policyStatusLabel = NSTextField(labelWithString: "Safety: \(SafetyPolicy.standard.summary)")
    let lidLimitLabel = NSTextField(labelWithString: "Lid close depends on macOS, power, and display setup.")
    let displayAwakeCheckbox = NSButton(checkboxWithTitle: "Keep display awake", target: nil, action: nil)
    let batteryPolicyCheckbox = NSButton(checkboxWithTitle: "Allow long sessions on battery", target: nil, action: nil)
    let processTriggerCheckbox = NSButton(checkboxWithTitle: "Auto-start for agent processes", target: nil, action: nil)
    let processIdentifiersField = NSTextField(
        string: ProcessTriggerConfiguration.agentDefaults.identifiers.joined(separator: ", ")
    )
    let processTriggerPillLabel = NSTextField(labelWithString: "Disabled")
    let processTriggerStatusLabel = NSTextField(labelWithString: "Process trigger idle")
    let agentActivityPillLabel = NSTextField(labelWithString: "Waiting")
    let agentActivityStatusLabel = NSTextField(labelWithString: "Agent activity idle")
    let agentLastTouchLabel = NSTextField(labelWithString: "Last touch: None")
    let hookManagementStatusLabel = NSTextField(labelWithString: "Hooks: Not installed by Caff")
    let installHooksButton = NSButton(title: "Install Hooks", target: nil, action: nil)
    let removeHooksButton = NSButton(title: "Remove Hooks", target: nil, action: nil)
    let workspaceTriggerCheckbox = NSButton(checkboxWithTitle: "Auto-start for workspace activity", target: nil, action: nil)
    let workspacePathsField = NSTextField(string: "")
    let workspaceTriggerPillLabel = NSTextField(labelWithString: "Disabled")
    let workspaceTriggerStatusLabel = NSTextField(labelWithString: "Workspace trigger idle")
    let notificationsCheckbox = NSButton(checkboxWithTitle: "Enable notifications", target: nil, action: nil)
    let historyStatusLabel = NSTextField(labelWithString: "History: Empty")
    let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    let clearHistoryButton = NSButton(title: "Clear History", target: nil, action: nil)
    let historyStore = SessionHistoryStore()
    let notificationBridge = NotificationBridge()
    private let settingsStore = AppSettingsStore()
    let statusStore = CaffStatusStore()
    var startButtons: [NSButton] = []
    var controlWindow: NSWindow?
    var activeSession: WakeSession?
    var history: [SessionHistoryEntry] = []
    var settings = AppSettings.standard
    var lastErrorMessage: String?
    var updateTimer: Timer?
    var processTriggerTimer: Timer?
    var agentActivityTimer: Timer?
    var workspaceTriggerTimer: Timer?
    var agentActivityState: AgentActivityState?
    var processTriggerState = ProcessTriggerState.inactive
    var workspaceTriggerState = WorkspaceTriggerState.inactive
    var lastAgentTouch: AgentActivityTouch?
    var processTriggerKeepingAwake = false
    var workspaceTriggerKeepingAwake = false
    var processTriggerReason = "Process trigger"
    var workspaceTriggerReason = "Workspace trigger"
    var processTriggerSummary = "Process trigger idle"
    var agentActivitySummary = "Agent activity idle"
    var workspaceTriggerSummary = "Workspace trigger idle"
    var keepDisplayAwake = false
    var allowLongSessionsOnBattery = false
    var processTriggerEnabled = false
    var workspaceTriggerEnabled = false
    var notificationsEnabled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        registerRemoteControlHandlers()
        settings = settingsStore.load()
        history = historyStore.load()
        statusItem.button?.title = "CAFF"
        rebuildMenu()
        updateStatusTitle()
        if settings.openControlWindowOnLaunch {
            showControlWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        processTriggerTimer?.invalidate()
        agentActivityTimer?.invalidate()
        workspaceTriggerTimer?.invalidate()
        if let activeSession {
            recordHistory(for: activeSession, result: .stopped)
        }
        do {
            try powerAssertions.stop()
        } catch {
            fputs("Caff failed to release wake assertion on quit: \(error)\n", stderr)
        }
        activeSession = nil
        writeStatusSnapshot()
    }

    @objc func startIndefinitely() {
        startSession(duration: .indefinitely)
    }

    @objc func startThirtyMinutes() {
        startSession(duration: .thirtyMinutes)
    }

    @objc func startOneHour() {
        startSession(duration: .oneHour)
    }

    @objc func startFourHours() {
        startSession(duration: .fourHours)
    }

    @objc func stopSessionFromMenu() {
        stopCurrentSessionFromUI()
    }

    @objc func toggleHeroSessionFromWindow() {
        if activeSession == nil {
            startSession(duration: .indefinitely)
        } else {
            stopCurrentSessionFromUI()
        }
    }

    @objc func showControlWindow() {
        let window = makeControlWindowIfNeeded()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.resetControlWindowScrollPosition()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.resetControlWindowScrollPosition()
        }
    }

    @objc func toggleDisplayAwake() {
        keepDisplayAwake.toggle()

        if let activeSession {
            do {
                try powerAssertions.start(options: options(for: activeSession))
                self.activeSession = activeSession.updatingAssertions(
                    powerAssertions.activeAssertions,
                    keepDisplayAwake: keepDisplayAwake
                )
                lastErrorMessage = nil
            } catch {
                keepDisplayAwake.toggle()
                clearSessionState()
                showError(error)
            }
        }

        rebuildMenu()
        updateStatusTitle()
    }

    @objc func toggleBatteryPolicy() {
        allowLongSessionsOnBattery.toggle()
        rebuildMenu()
        updateStatusTitle()
    }

    @objc func toggleNotifications() {
        notificationsEnabled.toggle()
        if notificationsEnabled {
            notificationBridge.requestAuthorizationIfNeeded()
        }
        rebuildMenu()
        updateStatusTitle()
    }

    @objc func clearHistory() {
        history = []
        historyStore.clear()
        rebuildMenu()
        updateStatusTitle()
    }

    @objc func cycleMenuBarMode() {
        settings.menuBarDisplayMode = settings.menuBarDisplayMode.next
        settingsStore.save(settings)
        rebuildMenu()
        updateStatusTitle()
    }

    @objc func toggleOpenWindowOnLaunch() {
        settings.openControlWindowOnLaunch.toggle()
        settingsStore.save(settings)
        rebuildMenu()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    @objc func tick() {
        guard let activeSession else {
            updateStatusTitle()
            return
        }

        if !enforceBatteryPolicy(activeSession) {
            return
        }

        if let endDate = activeSession.endDate, Date() >= endDate {
            let shouldPollAgentActivity = agentActivityState != nil
            stopSession(result: .timedOut)
            if shouldPollAgentActivity {
                pollAgentActivity()
            }
            return
        }

        updateStatusTitle()
    }

    @discardableResult
    func startSession(
        duration: SessionDuration,
        source: SessionSource = .manual,
        reason: String = "Caff is keeping this Mac awake"
    ) -> Bool {
        let startedAt = Date()
        let powerSource = PowerSourceMonitor.current()
        let safetyPolicy = currentSafetyPolicy()
        let sessionOptions = options(for: duration, source: source, reason: reason)

        do {
            try safetyPolicy.validate(duration: duration, powerSource: powerSource)
            try powerAssertions.start(options: sessionOptions)
            activeSession = WakeSession(
                options: sessionOptions,
                startedAt: startedAt,
                activeAssertions: powerAssertions.activeAssertions,
                endDate: safetyPolicy.effectiveEndDate(for: duration, startedAt: startedAt)
            )
            lastErrorMessage = nil
            scheduleTimer()
            sendNotification(title: "Caff started", body: sessionOptions.reason)
            rebuildMenu()
            updateStatusTitle()
            return true
        } catch {
            showError(error)
            return false
        }
    }

    func stopSession(
        result: SessionHistoryResult,
        errorMessage: String? = nil
    ) {
        let sessionToRecord = activeSession
        do {
            try powerAssertions.stop()
            if let sessionToRecord {
                recordHistory(
                    for: sessionToRecord,
                    result: result,
                    errorMessage: errorMessage
                )
                sendNotification(title: "Caff stopped", body: sessionToRecord.reason)
            }
            clearSessionState()
            lastErrorMessage = nil
            rebuildMenu()
            updateStatusTitle()
        } catch {
            showError(error)
        }
    }

    private func options(
        for duration: SessionDuration,
        source: SessionSource = .manual,
        reason: String = "Caff is keeping this Mac awake"
    ) -> SessionOptions {
        SessionOptions(
            duration: duration,
            source: source,
            keepDisplayAwake: keepDisplayAwake,
            reason: reason
        )
    }

    private func options(for session: WakeSession) -> SessionOptions {
        SessionOptions(
            duration: session.duration,
            source: session.source,
            keepDisplayAwake: keepDisplayAwake,
            reason: session.reason
        )
    }

    func currentSafetyPolicy() -> SafetyPolicy {
        SafetyPolicy(allowLongSessionsOnBattery: allowLongSessionsOnBattery)
    }

    private func enforceBatteryPolicy(_ activeSession: WakeSession) -> Bool {
        do {
            try currentSafetyPolicy().validate(
                duration: activeSession.duration,
                powerSource: PowerSourceMonitor.current()
            )
            return true
        } catch {
            stopSessionForPolicyViolation(error)
            return false
        }
    }

    func safetyNotes(for activeSession: WakeSession) -> [String] {
        currentSafetyPolicy().sessionNotes(
            for: activeSession.duration,
            powerSource: PowerSourceMonitor.current()
        )
    }

    private func stopSessionForPolicyViolation(_ policyError: Error) {
        do {
            try powerAssertions.stop()
            if let activeSession {
                recordHistory(for: activeSession, result: .policyStopped, errorMessage: String(describing: policyError))
                sendNotification(title: "Caff stopped by policy", body: String(describing: policyError))
            }
            clearSessionState()
        } catch {
            showError(error)
            return
        }

        showError(policyError)
    }

}
