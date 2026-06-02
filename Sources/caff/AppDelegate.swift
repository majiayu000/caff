import AppKit
import CaffCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var text = AppText.current
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let powerAssertions = PowerAssertionController()
    let windowStatusLabel = NSTextField(labelWithString: AppText.current.off)
    let heroEyebrowLabel = NSTextField(labelWithString: AppText.current.readyStandby)
    let heroTitleLabel = NSTextField(labelWithString: AppText.current.readyTitle)
    let heroMetaLabel = NSTextField(labelWithString: AppText.current.noActiveAssertion)
    let heroStatusDot = NSView()
    let heroActionButton = NSButton(title: AppText.current.start, target: nil, action: nil)
    let sourceProofLabel = NSTextField(labelWithString: AppText.current.localizedStatus("Source: None"))
    let assertionProofLabel = NSTextField(labelWithString: AppText.current.localizedStatus("Assertions: None"))
    let reasonProofLabel = NSTextField(labelWithString: AppText.current.localizedStatus("Reason: None"))
    let startedProofLabel = NSTextField(labelWithString: AppText.current.localizedStatus("Started: None"))
    let errorProofLabel = NSTextField(labelWithString: "")
    let policyStatusLabel = NSTextField(labelWithString: AppText.current.localizedStatus("Safety: \(AppText.current.safetySummary(.standard))"))
    let lidLimitLabel = NSTextField(labelWithString: AppText.current.lidLimit)
    let displayAwakeCheckbox = NSButton(checkboxWithTitle: AppText.current.keepDisplayAwake, target: nil, action: nil)
    let batteryPolicyCheckbox = NSButton(checkboxWithTitle: AppText.current.allowBatteryLongSessions, target: nil, action: nil)
    let agentActivityPillLabel = NSTextField(labelWithString: AppText.current.waiting)
    let agentActivityStatusLabel = NSTextField(labelWithString: AppText.current.localizedStatus("Agent activity idle"))
    let agentLastTouchLabel = NSTextField(labelWithString: AppText.current.localizedStatus("Last touch: None"))
    let hookManagementStatusLabel = NSTextField(labelWithString: AppText.current.hooksNotInstalled)
    let installHooksButton = NSButton(title: AppText.current.installHooks, target: nil, action: nil)
    let removeHooksButton = NSButton(title: AppText.current.removeHooks, target: nil, action: nil)
    let notificationsCheckbox = NSButton(checkboxWithTitle: AppText.current.enableNotifications, target: nil, action: nil)
    let languagePopupButton = NSPopUpButton(frame: .zero, pullsDown: false)
    let historyStatusLabel = NSTextField(labelWithString: AppText.current.localizedStatus("History: Empty"))
    let stopButton = NSButton(title: AppText.current.stop, target: nil, action: nil)
    let clearHistoryButton = NSButton(title: AppText.current.clearHistory, target: nil, action: nil)
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
    var agentActivityTimer: Timer?
    var agentActivityState: AgentActivityState?
    var lastAgentTouch: AgentActivityTouch?
    var agentActivitySummary = "Agent activity idle"
    var hookManagementStatus = HookManagementDisplayStatus.notInstalled
    var keepDisplayAwake = false
    var allowLongSessionsOnBattery = false
    var notificationsEnabled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        registerRemoteControlHandlers()
        settings = settingsStore.load()
        applyLanguageMode(rebuildControlWindow: false)
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
        agentActivityTimer?.invalidate()
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

    @objc func changeLanguageModeFromPopup(_ sender: NSPopUpButton) {
        let modes = AppLanguageMode.allCases
        let selectedIndex = sender.indexOfSelectedItem
        guard modes.indices.contains(selectedIndex) else {
            return
        }
        setLanguageMode(modes[selectedIndex])
    }

    @objc func changeLanguageModeFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = AppLanguageMode(rawValue: rawValue) else {
            return
        }
        setLanguageMode(mode)
    }

    func setLanguageMode(_ mode: AppLanguageMode) {
        guard settings.languageMode != mode else {
            return
        }
        settings.languageMode = mode
        settingsStore.save(settings)
        applyLanguageMode(rebuildControlWindow: true)
    }

    func applyLanguageMode(rebuildControlWindow: Bool) {
        text = AppText(language: settings.languageMode.resolvedLanguage())
        refreshAgentActivityLanguageText()
        refreshStaticControlText()

        let existingWindow = controlWindow
        let existingFrame = existingWindow?.frame
        let wasControlWindowVisible = existingWindow?.isVisible == true
        if rebuildControlWindow, existingWindow != nil {
            controlWindow?.close()
            controlWindow = nil
            startButtons = []
        }

        rebuildMenu()
        updateStatusTitle()

        if rebuildControlWindow, let existingFrame, wasControlWindowVisible {
            let window = makeControlWindowIfNeeded()
            window.setFrame(existingFrame, display: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func refreshStaticControlText() {
        lidLimitLabel.stringValue = text.lidLimit
        displayAwakeCheckbox.title = text.keepDisplayAwake
        batteryPolicyCheckbox.title = text.allowBatteryLongSessions
        notificationsCheckbox.title = text.enableNotifications
        installHooksButton.title = text.installHooks
        removeHooksButton.title = text.removeHooks
        hookManagementStatusLabel.stringValue = hookManagementStatus.localizedText(text)
        stopButton.title = text.stop
        clearHistoryButton.title = text.clearHistory
        refreshLanguagePopup()
    }

    func refreshLanguagePopup() {
        languagePopupButton.removeAllItems()
        for mode in AppLanguageMode.allCases {
            languagePopupButton.addItem(withTitle: text.languageModeLabel(mode))
        }
        if let index = AppLanguageMode.allCases.firstIndex(of: settings.languageMode) {
            languagePopupButton.selectItem(at: index)
        }
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
        reason: String? = nil
    ) -> Bool {
        let sessionReason = reason ?? "Caff is keeping this Mac awake"
        let startedAt = Date()
        let powerSource = PowerSourceMonitor.current()
        let safetyPolicy = currentSafetyPolicy()
        let sessionOptions = options(for: duration, source: source, reason: sessionReason)

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
            sendNotification(title: text.caffStarted, body: text.localizedReason(sessionOptions.reason))
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
                sendNotification(title: text.caffStopped, body: text.localizedReason(sessionToRecord.reason))
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
        reason: String
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
                sendNotification(title: text.caffStoppedByPolicy, body: String(describing: policyError))
            }
            clearSessionState()
        } catch {
            showError(error)
            return
        }

        showError(policyError)
    }

}
