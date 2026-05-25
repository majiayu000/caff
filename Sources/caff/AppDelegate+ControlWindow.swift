import AppKit

extension AppDelegate {
    func makeControlWindowIfNeeded() -> NSWindow {
        if let controlWindow {
            return controlWindow
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Caff"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 450, height: 540)
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
        AppLabelStyle.configureSecondary(policyStatusLabel)
        AppLabelStyle.configureSecondary(lidLimitLabel)

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
        AppLabelStyle.configureSecondary(processTriggerStatusLabel)
        workspaceTriggerCheckbox.target = self
        workspaceTriggerCheckbox.action = #selector(toggleWorkspaceTrigger)
        workspacePathsField.placeholderString = "~/Desktop/code, /path/to/workspace"
        workspacePathsField.font = .systemFont(ofSize: 12)
        AppLabelStyle.configureSecondary(workspaceTriggerStatusLabel)
        notificationsCheckbox.target = self
        notificationsCheckbox.action = #selector(toggleNotifications)
        AppLabelStyle.configureSecondary(historyStatusLabel)
        stopButton.target = self
        stopButton.action = #selector(stopSessionFromMenu)
        stopButton.bezelStyle = .rounded
        clearHistoryButton.target = self
        clearHistoryButton.action = #selector(clearHistory)
        clearHistoryButton.bezelStyle = .rounded

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
            agentLauncherPanel.view,
            workspaceTriggerCheckbox,
            workspacePathsField,
            workspaceTriggerStatusLabel,
            notificationsCheckbox,
            historyStatusLabel,
            clearHistoryButton,
            stopButton
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = contentView
        window.contentView = scrollView
        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
            proofStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            policyStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            lidLimitLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            startGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            processIdentifiersField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            processTriggerStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            agentLauncherPanel.view.widthAnchor.constraint(equalTo: stack.widthAnchor),
            workspacePathsField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            workspaceTriggerStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            historyStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            clearHistoryButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stopButton.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        controlWindow = window
        updateControlWindow()
        return window
    }

    func updateControlWindow() {
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
        notificationsCheckbox.state = notificationsEnabled ? .on : .off
        historyStatusLabel.stringValue = historyMenuSummary()
        clearHistoryButton.isEnabled = !history.isEmpty
        stopButton.isEnabled = isRunning
        agentLauncherPanel.update(isProcessRunning: agentRunner.isRunning, hasLauncherAssertion: activeSession?.source == .launcher)
        for button in startButtons {
            button.isEnabled = !isRunning
        }
    }

    private func startButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        startButtons.append(button)
        return button
    }

    private func configureProofLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
    }

    private func formatDate(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium)
    }
}
