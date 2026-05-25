import AppKit
import CaffCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let powerAssertions = PowerAssertionController()
    let agentRunner = AgentProcessRunner()
    let windowStatusLabel = NSTextField(labelWithString: "Off")
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
    let processTriggerStatusLabel = NSTextField(labelWithString: "Process trigger idle")
    let workspaceTriggerCheckbox = NSButton(checkboxWithTitle: "Auto-start for workspace activity", target: nil, action: nil)
    let workspacePathsField = NSTextField(string: "")
    let workspaceTriggerStatusLabel = NSTextField(labelWithString: "Workspace trigger idle")
    let notificationsCheckbox = NSButton(checkboxWithTitle: "Enable notifications", target: nil, action: nil)
    let historyStatusLabel = NSTextField(labelWithString: "History: Empty")
    let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    let clearHistoryButton = NSButton(title: "Clear History", target: nil, action: nil)
    private let historyStore = SessionHistoryStore()
    private let notificationBridge = NotificationBridge()
    private let settingsStore = AppSettingsStore()
    lazy var agentLauncherPanel = AgentLauncherPanel(
        onLaunch: { [weak self] command in self?.launchAgentCommand(command) },
        onReleaseAssertion: { [weak self] in self?.releaseLauncherAssertionOnly() },
        onTerminate: { [weak self] in self?.confirmTerminateAgentCommand() },
        onError: { [weak self] error in self?.showError(error) }
    )
    var startButtons: [NSButton] = []
    var controlWindow: NSWindow?
    var activeSession: WakeSession?
    var releasedLauncherSession: WakeSession?
    var history: [SessionHistoryEntry] = []
    private var settings = AppSettings.standard
    var lastErrorMessage: String?
    private var updateTimer: Timer?
    private var processTriggerTimer: Timer?
    private var workspaceTriggerTimer: Timer?
    private var processTriggerState = ProcessTriggerState.inactive
    private var workspaceTriggerState = WorkspaceTriggerState.inactive
    var processTriggerSummary = "Process trigger idle"
    var workspaceTriggerSummary = "Workspace trigger idle"
    var keepDisplayAwake = false
    var allowLongSessionsOnBattery = false
    var processTriggerEnabled = false
    var workspaceTriggerEnabled = false
    var notificationsEnabled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
        workspaceTriggerTimer?.invalidate()
        if let activeSession {
            recordHistory(for: activeSession, result: .stopped)
        }
        do {
            try powerAssertions.stop()
        } catch {
            fputs("Caff failed to release wake assertion on quit: \(error)\n", stderr)
        }
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

    @objc private func showControlWindow() {
        let window = makeControlWindowIfNeeded()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    @objc func toggleProcessTrigger() {
        processTriggerEnabled.toggle()
        processTriggerState = .inactive
        processTriggerSummary = processTriggerEnabled ? "Process trigger watching" : "Process trigger idle"

        if processTriggerEnabled {
            scheduleProcessTriggerTimer()
            pollProcessTrigger()
        } else {
            processTriggerTimer?.invalidate()
            processTriggerTimer = nil
            if activeSession?.source == .process {
                stopSession(result: .stopped)
            }
        }

        rebuildMenu()
        updateStatusTitle()
    }

    @objc func toggleWorkspaceTrigger() {
        workspaceTriggerEnabled.toggle()
        workspaceTriggerState = .inactive
        workspaceTriggerSummary = workspaceTriggerEnabled ? "Workspace trigger watching" : "Workspace trigger idle"

        if workspaceTriggerEnabled {
            scheduleWorkspaceTriggerTimer()
            pollWorkspaceTrigger()
        } else {
            workspaceTriggerTimer?.invalidate()
            workspaceTriggerTimer = nil
            if activeSession?.source == .workspace {
                stopSession(result: .stopped)
            }
        }

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

    @objc private func cycleMenuBarMode() {
        settings.menuBarDisplayMode = settings.menuBarDisplayMode.next
        settingsStore.save(settings)
        rebuildMenu()
        updateStatusTitle()
    }

    @objc private func toggleOpenWindowOnLaunch() {
        settings.openControlWindowOnLaunch.toggle()
        settingsStore.save(settings)
        rebuildMenu()
    }

    @objc private func pollProcessTrigger() {
        guard processTriggerEnabled else {
            return
        }

        let evaluator = ProcessTriggerEvaluator(configuration: currentProcessTriggerConfiguration())
        let (evaluation, nextState) = evaluator.evaluate(
            candidates: ProcessListScanner.snapshot(),
            previousState: processTriggerState
        )
        processTriggerState = nextState
        processTriggerSummary = evaluation.summary

        if evaluation.isKeepingAwake {
            if activeSession == nil {
                let started = startSession(
                    duration: .indefinitely,
                    source: .process,
                    reason: evaluation.reason
                )
                if !started {
                    processTriggerEnabled = false
                    processTriggerTimer?.invalidate()
                    processTriggerTimer = nil
                }
            }
        } else if activeSession?.source == .process {
            stopSession(result: .stopped)
        }

        rebuildMenu()
        updateStatusTitle()
    }

    @objc private func pollWorkspaceTrigger() {
        guard workspaceTriggerEnabled else {
            return
        }

        let configuration = currentWorkspaceTriggerConfiguration()
        let evaluator = WorkspaceTriggerEvaluator(configuration: configuration)
        let (evaluation, nextState) = evaluator.evaluate(
            activities: WorkspaceActivityScanner.activities(configuration: configuration),
            previousState: workspaceTriggerState
        )
        workspaceTriggerState = nextState
        workspaceTriggerSummary = evaluation.summary

        if evaluation.isKeepingAwake {
            if activeSession == nil {
                let started = startSession(
                    duration: .indefinitely,
                    source: .workspace,
                    reason: evaluation.reason
                )
                if !started {
                    workspaceTriggerEnabled = false
                    workspaceTriggerTimer?.invalidate()
                    workspaceTriggerTimer = nil
                }
            }
        } else if activeSession?.source == .workspace {
            stopSession(result: .stopped)
        }

        rebuildMenu()
        updateStatusTitle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func tick() {
        guard let activeSession else {
            updateStatusTitle()
            return
        }

        if !enforceBatteryPolicy(activeSession) {
            return
        }

        if let endDate = activeSession.endDate, Date() >= endDate {
            stopSession(result: .timedOut)
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
        errorMessage: String? = nil,
        exitStatus: Int32? = nil,
        terminationReason: String? = nil
    ) {
        let sessionToRecord = activeSession
        do {
            try powerAssertions.stop()
            if let sessionToRecord {
                recordHistory(
                    for: sessionToRecord,
                    result: result,
                    errorMessage: errorMessage,
                    exitStatus: exitStatus,
                    terminationReason: terminationReason
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

    private func currentProcessTriggerConfiguration() -> ProcessTriggerConfiguration {
        let identifiers = processIdentifiersField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return ProcessTriggerConfiguration(
            identifiers: identifiers.isEmpty ? ProcessTriggerConfiguration.agentDefaults.identifiers : identifiers,
            gracePeriodSeconds: currentSafetyPolicy().stopGracePeriodSeconds
        )
    }

    private func currentWorkspaceTriggerConfiguration() -> WorkspaceTriggerConfiguration {
        let paths = workspacePathsField.stringValue
            .split { character in
                character == "," || character == "\n"
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return WorkspaceTriggerConfiguration(
            paths: paths,
            recentActivityWindowSeconds: 300,
            gracePeriodSeconds: currentSafetyPolicy().stopGracePeriodSeconds
        )
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

    private func scheduleTimer() {
        updateTimer?.invalidate()
        let timer = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        updateTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleProcessTriggerTimer() {
        processTriggerTimer?.invalidate()
        let timer = Timer(
            timeInterval: 5,
            target: self,
            selector: #selector(pollProcessTrigger),
            userInfo: nil,
            repeats: true
        )
        processTriggerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleWorkspaceTriggerTimer() {
        workspaceTriggerTimer?.invalidate()
        let timer = Timer(
            timeInterval: 15,
            target: self,
            selector: #selector(pollWorkspaceTrigger),
            userInfo: nil,
            repeats: true
        )
        workspaceTriggerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func clearSessionState() {
        activeSession = nil
        updateTimer?.invalidate()
        updateTimer = nil
    }

    func updateStatusTitle() {
        statusItem.length = settings.menuBarDisplayMode == .iconOnly ? NSStatusItem.squareLength : NSStatusItem.variableLength
        statusItem.button?.title = menuBarTitle()
        updateControlWindow()
    }

    private func menuBarTitle() -> String {
        if settings.menuBarDisplayMode == .iconOnly {
            return "C"
        }

        guard let activeSession else {
            return lastErrorMessage == nil ? "CAFF" : "CAFF !"
        }

        switch settings.menuBarDisplayMode {
        case .iconOnly:
            return "C"
        case .title:
            return "CAFF"
        case .countdown:
            return "CAFF \(activeSession.compactStatus())"
        case .source:
            return "CAFF \(activeSession.sourceLabel)"
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()
        if let activeSession {
            menu.addItem(disabledMenuItem("Running: \(activeSession.sourceLabel) - \(activeSession.duration.label)"))
            menu.addItem(disabledMenuItem("Assertions: \(activeSession.assertionSummary)"))
            menu.addItem(disabledMenuItem("Reason: \(activeSession.reason)"))
            menu.addItem(disabledMenuItem("Safety: \(safetyNotes(for: activeSession).joined(separator: ", "))"))
            menu.addItem(menuItem("Stop", action: #selector(stopSessionFromMenu)))
        } else {
            if let lastErrorMessage {
                menu.addItem(disabledMenuItem("Last error: \(lastErrorMessage)"))
                menu.addItem(.separator())
            }
            menu.addItem(menuItem("Start Indefinitely", action: #selector(startIndefinitely)))
            menu.addItem(menuItem("Start 30 Minutes", action: #selector(startThirtyMinutes)))
            menu.addItem(menuItem("Start 1 Hour", action: #selector(startOneHour)))
            menu.addItem(menuItem("Start 4 Hours", action: #selector(startFourHours)))
        }
        menu.addItem(.separator())
        let displayItem = menuItem("Keep Display Awake", action: #selector(toggleDisplayAwake))
        displayItem.state = keepDisplayAwake ? .on : .off
        menu.addItem(displayItem)
        let batteryItem = menuItem("Allow Long Sessions on Battery", action: #selector(toggleBatteryPolicy))
        batteryItem.state = allowLongSessionsOnBattery ? .on : .off
        menu.addItem(batteryItem)
        let processItem = menuItem("Auto Start for Agent Processes", action: #selector(toggleProcessTrigger))
        processItem.state = processTriggerEnabled ? .on : .off
        menu.addItem(processItem)
        menu.addItem(disabledMenuItem(processTriggerSummary))
        let workspaceItem = menuItem("Auto Start for Workspace Activity", action: #selector(toggleWorkspaceTrigger))
        workspaceItem.state = workspaceTriggerEnabled ? .on : .off
        menu.addItem(workspaceItem)
        menu.addItem(disabledMenuItem(workspaceTriggerSummary))
        menu.addItem(disabledMenuItem("Lid close depends on macOS power/display policy"))
        let notificationsItem = menuItem("Enable Notifications", action: #selector(toggleNotifications))
        notificationsItem.state = notificationsEnabled ? .on : .off
        menu.addItem(notificationsItem)
        menu.addItem(menuItem("Menu Bar Mode: \(settings.menuBarDisplayMode.label)", action: #selector(cycleMenuBarMode)))
        let launchWindowItem = menuItem("Show Window on Launch", action: #selector(toggleOpenWindowOnLaunch))
        launchWindowItem.state = settings.openControlWindowOnLaunch ? .on : .off
        menu.addItem(launchWindowItem)
        menu.addItem(disabledMenuItem(historyMenuSummary()))
        menu.addItem(menuItem("Clear History", action: #selector(clearHistory)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Show Caff", action: #selector(showControlWindow)))
        menu.addItem(menuItem("Quit Caff", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func recordHistory(
        for session: WakeSession,
        result: SessionHistoryResult,
        errorMessage: String? = nil,
        exitStatus: Int32? = nil,
        terminationReason: String? = nil
    ) {
        let entry = SessionHistoryEntry(
            session: session,
            result: result,
            errorMessage: errorMessage,
            exitStatus: exitStatus,
            terminationReason: terminationReason
        )
        history = historyStore.append(entry, to: history)
    }

    func historyMenuSummary() -> String {
        guard let latest = history.first else {
            return "History: Empty"
        }

        return "History: \(latest.summary)"
    }

    func sendNotification(title: String, body: String) {
        guard notificationsEnabled else {
            return
        }

        notificationBridge.send(title: title, body: body)
    }

    private func menuItem(_ title: String, action: Selector?, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    func showError(_ error: Error) {
        lastErrorMessage = String(describing: error)
        sendNotification(title: "Caff error", body: lastErrorMessage ?? "Unknown error")
        rebuildMenu()
        updateStatusTitle()

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Caff could not update the wake session"
        alert.informativeText = lastErrorMessage ?? "Unknown error"
        alert.runModal()
    }
}
