import AppKit
import CaffCore

extension AppDelegate {
    func makeControlWindowIfNeeded() -> NSWindow {
        if let controlWindow {
            return controlWindow
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 780),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Caff"
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 560)
        window.appearance = NSAppearance(named: .aqua)

        configureControls()

        let contentView = ControlWindowContentView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = CaffPanelStyle.background.cgColor

        let hero = heroView()
        let currentSessionSection = sectionView(
            title: "Current Session",
            subtitle: "Current session details reported by Caff",
            symbolName: "checkmark.shield.fill",
            views: [insetView(proofStack()), insetView(policyStatusLabel), insetView(lidLimitLabel)]
        )
        let keepAwakeSection = sectionView(
            title: "Wake Lock",
            subtitle: "Keep your Mac awake while agents are working",
            symbolName: "bolt.fill",
            views: [wakeLockRows()]
        )
        let automationSection = sectionView(
            title: "Automation",
            subtitle: "Agent hook events keep Caff in sync with active CLI work",
            symbolName: "bolt.badge.clock.fill",
            views: automationViews()
        )
        let historySection = sectionView(
            title: "History",
            subtitle: "Recent wake-lock sessions and trigger events",
            symbolName: "clock.arrow.circlepath",
            views: [historyRows()]
        )
        let sections = [
            hero,
            currentSessionSection,
            keepAwakeSection,
            automationSection,
            historySection
        ]

        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = CaffPanelStyle.background
        scrollView.documentView = contentView
        window.contentView = scrollView

        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])
        NSLayoutConstraint.activate(sections.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })

        controlWindow = window
        updateControlWindow()
        DispatchQueue.main.async { [weak self] in
            self?.resetControlWindowScrollPosition()
        }
        return window
    }

    func resetControlWindowScrollPosition() {
        guard let scrollView = controlWindow?.contentView as? NSScrollView else {
            return
        }
        controlWindow?.makeFirstResponder(nil)
        scrollView.layoutSubtreeIfNeeded()
        scrollView.documentView?.layoutSubtreeIfNeeded()
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        let clipHeight = scrollView.contentView.bounds.height
        let y = scrollView.documentView?.isFlipped == true ? 0 : max(0, documentHeight - clipHeight)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func updateControlWindow() {
        let isRunning = activeSession != nil
        let statusText: String

        if let activeSession {
            let compactStatus = activeSession.compactStatus()
            statusText = activeSession.endDate == nil ? "On" : "On: \(compactStatus)"
            windowStatusLabel.textColor = CaffPanelStyle.good
            sourceProofLabel.stringValue = "Source: \(activeSession.sourceLabel)"
            assertionProofLabel.stringValue = "Assertions: \(activeSession.assertionSummary)"
            reasonProofLabel.stringValue = "Reason: \(activeSession.reason)"
            startedProofLabel.stringValue = "Started: \(formatDate(activeSession.startedAt))"
            errorProofLabel.stringValue = activeSession.errorMessage.map { "Error: \($0)" } ?? ""
            policyStatusLabel.stringValue = "Safety: \(safetyNotes(for: activeSession).joined(separator: ", "))"
        } else {
            statusText = lastErrorMessage == nil ? "Off" : "Error"
            windowStatusLabel.textColor = lastErrorMessage == nil ? CaffPanelStyle.inkSecondary : CaffPanelStyle.bad
            sourceProofLabel.stringValue = "Source: None"
            assertionProofLabel.stringValue = "Assertions: None"
            reasonProofLabel.stringValue = "Reason: None"
            startedProofLabel.stringValue = "Started: None"
            errorProofLabel.stringValue = lastErrorMessage.map { "Error: \($0)" } ?? ""
            policyStatusLabel.stringValue = "Safety: \(currentSafetyPolicy().summary)"
        }

        windowStatusLabel.stringValue = statusText
        updateHero()
        displayAwakeCheckbox.state = keepDisplayAwake ? .on : .off
        batteryPolicyCheckbox.state = allowLongSessionsOnBattery ? .on : .off
        let agentEvaluation = AgentActivityCooldown.evaluate(state: agentActivityState)
        agentActivityPillLabel.stringValue = agentEvaluation.isKeepingAwake ? "Active" : "Waiting"
        agentActivityPillLabel.textColor = agentEvaluation.isKeepingAwake ? CaffPanelStyle.good : CaffPanelStyle.inkTertiary
        agentActivityStatusLabel.stringValue = agentActivitySummary
        agentLastTouchLabel.stringValue = lastAgentTouch.map {
            "Last touch: \($0.source) at \(formatDate($0.receivedAt))"
        } ?? "Last touch: None"
        notificationsCheckbox.state = notificationsEnabled ? .on : .off
        historyStatusLabel.stringValue = historyMenuSummary()
        clearHistoryButton.isEnabled = !history.isEmpty
        stopButton.isEnabled = isRunning
        heroActionButton.title = isRunning ? "Stop" : "Start"
        heroActionButton.contentTintColor = isRunning ? CaffPanelStyle.bad : CaffPanelStyle.accent
        for button in startButtons {
            button.isEnabled = !isRunning
        }
    }

    private func configureControls() {
        windowStatusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        windowStatusLabel.alignment = .center
        windowStatusLabel.lineBreakMode = .byTruncatingTail
        windowStatusLabel.maximumNumberOfLines = 1
        windowStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        heroEyebrowLabel.font = .systemFont(ofSize: 10, weight: .bold)
        heroEyebrowLabel.textColor = CaffPanelStyle.good
        heroEyebrowLabel.lineBreakMode = .byTruncatingTail
        heroTitleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        heroTitleLabel.textColor = CaffPanelStyle.ink
        heroTitleLabel.lineBreakMode = .byTruncatingTail
        heroMetaLabel.font = .systemFont(ofSize: 12)
        heroMetaLabel.textColor = CaffPanelStyle.inkSecondary
        heroMetaLabel.lineBreakMode = .byTruncatingMiddle
        heroActionButton.target = self
        heroActionButton.action = #selector(toggleHeroSessionFromWindow)
        CaffPanelStyle.styleRoundedButton(heroActionButton)
        AppLabelStyle.configureProof(sourceProofLabel)
        AppLabelStyle.configureProof(assertionProofLabel)
        AppLabelStyle.configureProof(reasonProofLabel)
        AppLabelStyle.configureProof(startedProofLabel)
        AppLabelStyle.configureProof(errorProofLabel)
        AppLabelStyle.configureSecondary(policyStatusLabel)
        AppLabelStyle.configureSecondary(lidLimitLabel)
        policyStatusLabel.alignment = .left
        lidLimitLabel.alignment = .left

        displayAwakeCheckbox.target = self
        displayAwakeCheckbox.action = #selector(toggleDisplayAwake)
        batteryPolicyCheckbox.target = self
        batteryPolicyCheckbox.action = #selector(toggleBatteryPolicy)
        notificationsCheckbox.target = self
        notificationsCheckbox.action = #selector(toggleNotifications)
        for checkbox in [
            displayAwakeCheckbox,
            batteryPolicyCheckbox,
            notificationsCheckbox
        ] {
            checkbox.controlSize = .small
        }

        configurePillLabel(agentActivityPillLabel)
        AppLabelStyle.configureSecondary(agentActivityStatusLabel)
        agentActivityStatusLabel.alignment = .left
        AppLabelStyle.configureSecondary(agentLastTouchLabel)
        agentLastTouchLabel.alignment = .left
        AppLabelStyle.configureSecondary(hookManagementStatusLabel)
        hookManagementStatusLabel.alignment = .left
        AppLabelStyle.configureSecondary(historyStatusLabel)
        historyStatusLabel.alignment = .left

        stopButton.target = self
        stopButton.action = #selector(stopSessionFromMenu)
        CaffPanelStyle.styleRoundedButton(stopButton)
        stopButton.contentTintColor = CaffPanelStyle.bad
        clearHistoryButton.target = self
        clearHistoryButton.action = #selector(clearHistory)
        CaffPanelStyle.styleRoundedButton(clearHistoryButton)
        installHooksButton.target = self
        installHooksButton.action = #selector(installAgentHooks)
        CaffPanelStyle.styleRoundedButton(installHooksButton)
        removeHooksButton.target = self
        removeHooksButton.action = #selector(removeAgentHooks)
        CaffPanelStyle.styleRoundedButton(removeHooksButton)
        removeHooksButton.contentTintColor = CaffPanelStyle.bad
    }

    private func updateHero() {
        if let activeSession {
            heroEyebrowLabel.stringValue = "CAFFEINATED - AWAKE"
            heroEyebrowLabel.textColor = CaffPanelStyle.good
            heroStatusDot.layer?.backgroundColor = CaffPanelStyle.good.cgColor
            heroTitleLabel.stringValue = keepDisplayAwake ? "Display will stay on" : "Mac will stay awake"
            heroMetaLabel.stringValue = "\(activeSession.compactStatus()) - triggered by \(activeSession.sourceLabel.lowercased()) - \(activeSession.assertionSummary)"
            return
        }

        if lastErrorMessage == nil {
            heroEyebrowLabel.stringValue = "READY - STANDBY"
            heroEyebrowLabel.textColor = CaffPanelStyle.inkTertiary
            heroStatusDot.layer?.backgroundColor = CaffPanelStyle.inkTertiary.cgColor
            heroTitleLabel.stringValue = "Ready to keep awake"
            heroMetaLabel.stringValue = "No active power assertion - choose a duration or use agent hooks"
        } else {
            heroEyebrowLabel.stringValue = "NEEDS ATTENTION"
            heroEyebrowLabel.textColor = CaffPanelStyle.bad
            heroStatusDot.layer?.backgroundColor = CaffPanelStyle.bad.cgColor
            heroTitleLabel.stringValue = "Wake lock needs attention"
            heroMetaLabel.stringValue = lastErrorMessage ?? "Unknown error"
        }
    }

    private func heroView() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        CaffPanelStyle.applyCard(container, radius: 14, borderColor: CaffPanelStyle.heroBorder)
        container.layer?.backgroundColor = CaffPanelStyle.heroTint.cgColor

        let iconView = heroIconView()
        heroStatusDot.translatesAutoresizingMaskIntoConstraints = false
        heroStatusDot.wantsLayer = true
        heroStatusDot.layer?.cornerRadius = 5
        heroStatusDot.layer?.backgroundColor = CaffPanelStyle.inkTertiary.cgColor
        NSLayoutConstraint.activate([
            heroStatusDot.widthAnchor.constraint(equalToConstant: 10),
            heroStatusDot.heightAnchor.constraint(equalToConstant: 10)
        ])

        let statusRow = NSStackView(views: [heroStatusDot, heroEyebrowLabel, statusBadgeView()])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        let textStack = NSStackView(views: [statusRow, heroTitleLabel, heroMetaLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 5

        let spacer = NSView()
        heroActionButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heroActionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            heroActionButton.heightAnchor.constraint(equalToConstant: 40)
        ])

        let row = NSStackView(views: [iconView, textStack, spacer, heroActionButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        heroActionButton.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 106)
        ])
        return container
    }

    private func heroIconView() -> NSView {
        let tile = NSView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 14
        tile.layer?.backgroundColor = CaffPanelStyle.coffee.cgColor
        tile.layer?.shadowColor = CaffPanelStyle.coffeeDeep.cgColor
        tile.layer?.shadowOpacity = 0.20
        tile.layer?.shadowRadius = 12
        tile.layer?.shadowOffset = CGSize(width: 0, height: 6)

        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(iconView)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 56),
            tile.heightAnchor.constraint(equalToConstant: 56),
            iconView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40)
        ])
        return tile
    }

    private func statusBadgeView() -> NSView {
        let badge = NSView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 14
        badge.layer?.backgroundColor = CaffPanelStyle.goodSoft.cgColor
        badge.layer?.borderWidth = 1
        badge.layer?.borderColor = CaffPanelStyle.line.cgColor
        badge.addSubview(windowStatusLabel)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
            badge.heightAnchor.constraint(equalToConstant: 28),
            windowStatusLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            windowStatusLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            windowStatusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: badge.leadingAnchor, constant: 14),
            windowStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: badge.trailingAnchor, constant: -14)
        ])
        return badge
    }

    private func proofStack() -> NSStackView {
        let stack = NSStackView(views: [
            sourceProofLabel,
            assertionProofLabel,
            reasonProofLabel,
            startedProofLabel,
            errorProofLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        return stack
    }

    private func startGrid() -> NSGridView {
        let grid = NSGridView(views: [
            [
                startButton("Indefinitely", action: #selector(startIndefinitely)),
                startButton("30 Minutes", action: #selector(startThirtyMinutes))
            ],
            [
                startButton("1 Hour", action: #selector(startOneHour)),
                startButton("4 Hours", action: #selector(startFourHours))
            ]
        ])
        grid.columnSpacing = 10
        grid.rowSpacing = 10
        grid.xPlacement = .fill
        for button in startButtons {
            button.controlSize = .regular
        }
        return grid
    }

    private func sessionOptionRow() -> NSStackView {
        let row = NSStackView(views: [displayAwakeCheckbox, batteryPolicyCheckbox])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        return row
    }

    private func wakeLockRows() -> NSView {
        let stack = NSStackView(views: [
            settingsRow(
                title: "Keep display awake",
                subtitle: "Prevents the screen from dimming or turning off",
                control: displayAwakeCheckbox
            ),
            divider(),
            settingsRow(
                title: "Allow long sessions on battery",
                subtitle: "Skip the safety timeout when running on battery power",
                control: batteryPolicyCheckbox
            ),
            divider(),
            manualControlView()
        ])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func manualControlView() -> NSView {
        let title = NSTextField(labelWithString: "Manual control")
        CaffPanelStyle.configureTitle(title)
        let subtitle = NSTextField(labelWithString: "Pick a duration or stop the current wake lock")
        CaffPanelStyle.configureBody(subtitle)
        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3

        let controls = NSStackView(views: [startGrid(), stopButton])
        controls.orientation = .vertical
        controls.alignment = .width
        controls.spacing = 8

        let row = NSStackView(views: [labels, controls])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        row.translatesAutoresizingMaskIntoConstraints = false
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controls.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            controls.widthAnchor.constraint(equalToConstant: 300)
        ])
        return paddedRow(row)
    }

    private func automationViews() -> [NSView] {
        [
            agentActivityHookGroup()
        ]
    }

    private func historyRows() -> NSView {
        let stack = NSStackView(views: [
            settingsRow(
                title: "Enable notifications",
                subtitle: "Notify when Caff starts or stops",
                control: notificationsCheckbox
            ),
            divider(),
            insetView(historyStatusLabel),
            insetView(clearHistoryButton, top: 0, bottom: 14)
        ])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        return stack
    }

    private func agentActivityHookGroup() -> NSView {
        let icon = symbolTile(
            symbolName: "bolt.fill",
            fill: CaffPanelStyle.accentSoft,
            tint: CaffPanelStyle.accent,
            size: 28
        )
        let title = NSTextField(labelWithString: "Agent Activity Hook")
        CaffPanelStyle.configureTitle(title)
        let subtitle = NSTextField(labelWithString: "Refreshes Caff when Codex or Claude hook events arrive")
        CaffPanelStyle.configureBody(subtitle)
        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3

        let spacer = NSView()
        let row = NSStackView(views: [icon, labels, spacer, statusPillView(agentActivityPillLabel)])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let hookButtons = NSStackView(views: [installHooksButton, removeHooksButton])
        hookButtons.orientation = .horizontal
        hookButtons.alignment = .centerY
        hookButtons.distribution = .fillEqually
        hookButtons.spacing = 8

        let stack = NSStackView(views: [
            paddedRow(row),
            insetView(agentActivityStatusLabel, top: 0, bottom: 4),
            insetView(agentLastTouchLabel, top: 0, bottom: 4),
            insetView(hookManagementStatusLabel, top: 0, bottom: 8),
            insetView(hookButtons, top: 0, bottom: 12)
        ])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func sectionView(title: String, subtitle: String, symbolName: String, views: [NSView]) -> NSView {
        let header = sectionHeader(title: title, subtitle: subtitle, symbolName: symbolName)

        let body = NSStackView(views: views)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        let stack = NSStackView(views: [header, divider(), body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        CaffPanelStyle.applyCard(container)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        NSLayoutConstraint.activate(views.map { $0.widthAnchor.constraint(equalTo: body.widthAnchor) })
        return container
    }

    private func sectionHeader(title: String, subtitle: String, symbolName: String) -> NSView {
        let icon = symbolTile(symbolName: symbolName, fill: CaffPanelStyle.accentSoft, tint: CaffPanelStyle.accent, size: 28)
        let titleLabel = NSTextField(labelWithString: title)
        CaffPanelStyle.configureTitle(titleLabel, size: 14)
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        CaffPanelStyle.configureBody(subtitleLabel, size: 12)
        let labelStack = NSStackView(views: [titleLabel, subtitleLabel])
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 2

        let row = NSStackView(views: [icon, labelStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
        return container
    }

    private func settingsRow(
        title: String,
        subtitle: String,
        control: NSView,
        trailing: NSView? = nil
    ) -> NSView {
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        CaffPanelStyle.configureBody(subtitleLabel)

        let labels: NSStackView
        if let checkbox = control as? NSButton {
            checkbox.title = title
            checkbox.font = .systemFont(ofSize: 13, weight: .semibold)
            labels = NSStackView(views: [checkbox, subtitleLabel])
        } else {
            let titleLabel = NSTextField(labelWithString: title)
            CaffPanelStyle.configureTitle(titleLabel)
            labels = NSStackView(views: [titleLabel, subtitleLabel])
        }
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3

        var views: [NSView] = [labels]
        let spacer = NSView()
        views.append(spacer)
        if let trailing {
            views.append(trailing)
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailing?.setContentHuggingPriority(.required, for: .horizontal)
        return paddedRow(row)
    }

    private func paddedRow(_ row: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        return container
    }

    private func insetView(_ view: NSView, top: CGFloat = 10, bottom: CGFloat = 10) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: top),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottom)
        ])
        return container
    }

    private func configurePillLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = CaffPanelStyle.inkTertiary
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
    }

    private func statusPillView(_ label: NSTextField) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.backgroundColor = CaffPanelStyle.goodSoft.cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = CaffPanelStyle.line.cgColor
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 128),
            container.heightAnchor.constraint(equalToConstant: 28),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14)
        ])
        return container
    }

    private func symbolTile(symbolName: String, fill: NSColor, tint: NSColor, size: CGFloat) -> NSView {
        let tile = NSView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 8
        tile.layer?.backgroundColor = fill.cgColor

        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        imageView.contentTintColor = tint
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(imageView)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: size),
            tile.heightAnchor.constraint(equalToConstant: size),
            imageView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: size * 0.54),
            imageView.heightAnchor.constraint(equalToConstant: size * 0.54)
        ])
        return tile
    }

    private func startButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        CaffPanelStyle.styleRoundedButton(button)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        startButtons.append(button)
        return button
    }

    private func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func formatDate(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium)
    }
}

private final class ControlWindowContentView: NSView {
    override var isFlipped: Bool { true }
}
