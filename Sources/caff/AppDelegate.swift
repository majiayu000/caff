import AppKit
import CaffCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let powerAssertions = PowerAssertionController()
    private let windowStatusLabel = NSTextField(labelWithString: "Off")
    private let sourceProofLabel = NSTextField(labelWithString: "Source: None")
    private let assertionProofLabel = NSTextField(labelWithString: "Assertions: None")
    private let reasonProofLabel = NSTextField(labelWithString: "Reason: None")
    private let startedProofLabel = NSTextField(labelWithString: "Started: None")
    private let errorProofLabel = NSTextField(labelWithString: "")
    private let policyStatusLabel = NSTextField(labelWithString: "Safety: \(SafetyPolicy.standard.summary)")
    private let lidLimitLabel = NSTextField(labelWithString: "Lid close depends on macOS, power, and display setup.")
    private let displayAwakeCheckbox = NSButton(checkboxWithTitle: "Keep display awake", target: nil, action: nil)
    private let batteryPolicyCheckbox = NSButton(checkboxWithTitle: "Allow long sessions on battery", target: nil, action: nil)
    private let processTriggerCheckbox = NSButton(checkboxWithTitle: "Auto-start for agent processes", target: nil, action: nil)
    private let processIdentifiersField = NSTextField(
        string: ProcessTriggerConfiguration.agentDefaults.identifiers.joined(separator: ", ")
    )
    private let processTriggerStatusLabel = NSTextField(labelWithString: "Process trigger idle")
    private let workspaceTriggerCheckbox = NSButton(checkboxWithTitle: "Auto-start for workspace activity", target: nil, action: nil)
    private let workspacePathsField = NSTextField(string: "")
    private let workspaceTriggerStatusLabel = NSTextField(labelWithString: "Workspace trigger idle")
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private var startButtons: [NSButton] = []
    private var controlWindow: NSWindow?
    private var activeSession: WakeSession?
    private var lastErrorMessage: String?
    private var updateTimer: Timer?
    private var processTriggerTimer: Timer?
    private var workspaceTriggerTimer: Timer?
    private var processTriggerState = ProcessTriggerState.inactive
    private var workspaceTriggerState = WorkspaceTriggerState.inactive
    private var processTriggerSummary = "Process trigger idle"
    private var workspaceTriggerSummary = "Workspace trigger idle"
    private var keepDisplayAwake = false
    private var allowLongSessionsOnBattery = false
    private var processTriggerEnabled = false
    private var workspaceTriggerEnabled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "CAFF"
        rebuildMenu()
        updateStatusTitle()
        showControlWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        processTriggerTimer?.invalidate()
        workspaceTriggerTimer?.invalidate()
        do {
            try powerAssertions.stop()
        } catch {
            fputs("Caff failed to release wake assertion on quit: \(error)\n", stderr)
        }
    }

    @objc private func startIndefinitely() {
        startSession(duration: .indefinitely)
    }

    @objc private func startThirtyMinutes() {
        startSession(duration: .thirtyMinutes)
    }

    @objc private func startOneHour() {
        startSession(duration: .oneHour)
    }

    @objc private func startFourHours() {
        startSession(duration: .fourHours)
    }

    @objc private func stopSessionFromMenu() {
        stopSession()
    }

    @objc private func showControlWindow() {
        let window = makeControlWindowIfNeeded()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleDisplayAwake() {
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

    @objc private func toggleBatteryPolicy() {
        allowLongSessionsOnBattery.toggle()
        rebuildMenu()
        updateStatusTitle()
    }

    @objc private func toggleProcessTrigger() {
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
                stopSession()
            }
        }

        rebuildMenu()
        updateStatusTitle()
    }

    @objc private func toggleWorkspaceTrigger() {
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
                stopSession()
            }
        }

        rebuildMenu()
        updateStatusTitle()
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
            stopSession()
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
            stopSession()
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
            stopSession()
            return
        }

        updateStatusTitle()
    }

    @discardableResult
    private func startSession(
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
            rebuildMenu()
            updateStatusTitle()
            return true
        } catch {
            showError(error)
            return false
        }
    }

    private func stopSession() {
        do {
            try powerAssertions.stop()
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

    private func currentSafetyPolicy() -> SafetyPolicy {
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

    private func safetyNotes(for activeSession: WakeSession) -> [String] {
        currentSafetyPolicy().sessionNotes(
            for: activeSession.duration,
            powerSource: PowerSourceMonitor.current()
        )
    }

    private func stopSessionForPolicyViolation(_ policyError: Error) {
        do {
            try powerAssertions.stop()
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

    private func updateStatusTitle() {
        guard let activeSession else {
            statusItem.button?.title = lastErrorMessage == nil ? "CAFF" : "CAFF !"
            updateControlWindow()
            return
        }

        statusItem.button?.title = "CAFF \(activeSession.compactStatus())"
        updateControlWindow()
    }

    private func rebuildMenu() {
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

        menu.addItem(.separator())
        menu.addItem(menuItem("Show Caff", action: #selector(showControlWindow)))
        menu.addItem(menuItem("Quit Caff", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func makeControlWindowIfNeeded() -> NSWindow {
        if let controlWindow {
            return controlWindow
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Caff"
        window.isReleasedWhenClosed = false

        let titleLabel = NSTextField(labelWithString: "Caff")
        titleLabel.font = .boldSystemFont(ofSize: 24)
        titleLabel.alignment = .center

        windowStatusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        windowStatusLabel.alignment = .center

        let proofStack = NSStackView(views: [
            sourceProofLabel,
            assertionProofLabel,
            reasonProofLabel,
            startedProofLabel,
            errorProofLabel
        ])
        proofStack.orientation = .vertical
        proofStack.alignment = .leading
        proofStack.spacing = 4
        proofStack.translatesAutoresizingMaskIntoConstraints = false
        configureProofLabel(sourceProofLabel)
        configureProofLabel(assertionProofLabel)
        configureProofLabel(reasonProofLabel)
        configureProofLabel(startedProofLabel)
        configureProofLabel(errorProofLabel)
        configureSecondaryLabel(policyStatusLabel)
        configureSecondaryLabel(lidLimitLabel)

        let startGrid = NSGridView(views: [
            [
                startButton("Indefinitely", action: #selector(startIndefinitely)),
                startButton("30 Minutes", action: #selector(startThirtyMinutes))
            ],
            [
                startButton("1 Hour", action: #selector(startOneHour)),
                startButton("4 Hours", action: #selector(startFourHours))
            ]
        ])
        startGrid.columnSpacing = 10
        startGrid.rowSpacing = 10
        startGrid.xPlacement = .fill

        displayAwakeCheckbox.target = self
        displayAwakeCheckbox.action = #selector(toggleDisplayAwake)

        batteryPolicyCheckbox.target = self
        batteryPolicyCheckbox.action = #selector(toggleBatteryPolicy)

        processTriggerCheckbox.target = self
        processTriggerCheckbox.action = #selector(toggleProcessTrigger)
        processIdentifiersField.placeholderString = "codex, claude, node, python, cargo, swift"
        processIdentifiersField.font = .systemFont(ofSize: 12)
        configureSecondaryLabel(processTriggerStatusLabel)

        workspaceTriggerCheckbox.target = self
        workspaceTriggerCheckbox.action = #selector(toggleWorkspaceTrigger)
        workspacePathsField.placeholderString = "~/Desktop/code, /path/to/workspace"
        workspacePathsField.font = .systemFont(ofSize: 12)
        configureSecondaryLabel(workspaceTriggerStatusLabel)

        stopButton.target = self
        stopButton.action = #selector(stopSessionFromMenu)
        stopButton.bezelStyle = .rounded

        let stack = NSStackView(views: [
            titleLabel,
            windowStatusLabel,
            proofStack,
            policyStatusLabel,
            lidLimitLabel,
            startGrid,
            displayAwakeCheckbox,
            batteryPolicyCheckbox,
            processTriggerCheckbox,
            processIdentifiersField,
            processTriggerStatusLabel,
            workspaceTriggerCheckbox,
            workspacePathsField,
            workspaceTriggerStatusLabel,
            stopButton
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(stack)
        window.contentView = contentView

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            proofStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            policyStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            lidLimitLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            startGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            processIdentifiersField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            processTriggerStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            workspacePathsField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            workspaceTriggerStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stopButton.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        controlWindow = window
        updateControlWindow()
        return window
    }

    private func startButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        startButtons.append(button)
        return button
    }

    private func updateControlWindow() {
        let isRunning = activeSession != nil
        let statusText: String

        if let activeSession {
            let compactStatus = activeSession.compactStatus()
            statusText = activeSession.endDate == nil ? "On" : "On: \(compactStatus)"
            sourceProofLabel.stringValue = "Source: \(activeSession.sourceLabel)"
            assertionProofLabel.stringValue = "Assertions: \(activeSession.assertionSummary)"
            reasonProofLabel.stringValue = "Reason: \(activeSession.reason)"
            startedProofLabel.stringValue = "Started: \(formatDate(activeSession.startedAt))"
            errorProofLabel.stringValue = activeSession.errorMessage.map { "Error: \($0)" } ?? ""
            policyStatusLabel.stringValue = "Safety: \(safetyNotes(for: activeSession).joined(separator: ", "))"
        } else {
            statusText = lastErrorMessage == nil ? "Off" : "Error"
            sourceProofLabel.stringValue = "Source: None"
            assertionProofLabel.stringValue = "Assertions: None"
            reasonProofLabel.stringValue = "Reason: None"
            startedProofLabel.stringValue = "Started: None"
            errorProofLabel.stringValue = lastErrorMessage.map { "Error: \($0)" } ?? ""
            policyStatusLabel.stringValue = "Safety: \(currentSafetyPolicy().summary)"
        }

        windowStatusLabel.stringValue = statusText
        displayAwakeCheckbox.state = keepDisplayAwake ? .on : .off
        batteryPolicyCheckbox.state = allowLongSessionsOnBattery ? .on : .off
        processTriggerCheckbox.state = processTriggerEnabled ? .on : .off
        processTriggerStatusLabel.stringValue = processTriggerSummary
        workspaceTriggerCheckbox.state = workspaceTriggerEnabled ? .on : .off
        workspaceTriggerStatusLabel.stringValue = workspaceTriggerSummary
        stopButton.isEnabled = isRunning
        for button in startButtons {
            button.isEnabled = !isRunning
        }
    }

    private func configureProofLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
    }

    private func configureSecondaryLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
    }

    private func formatDate(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium)
    }

    private func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func menuItem(_ title: String, action: Selector?, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func showError(_ error: Error) {
        lastErrorMessage = String(describing: error)
        rebuildMenu()
        updateStatusTitle()

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Caff could not update the wake session"
        alert.informativeText = lastErrorMessage ?? "Unknown error"
        alert.runModal()
    }
}
