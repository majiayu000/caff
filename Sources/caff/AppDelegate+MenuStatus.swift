import AppKit

extension AppDelegate {
    func updateStatusTitle() {
        statusItem.length = settings.menuBarDisplayMode == .iconOnly ? NSStatusItem.squareLength : NSStatusItem.variableLength
        statusItem.button?.title = menuBarTitle()
        updateControlWindow()
        writeStatusSnapshot()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        if let activeSession {
            menu.addItem(disabledMenuItem(text.label(text.localizedStatus("Running"), "\(text.sourceLabel(activeSession.source)) - \(text.durationLabel(activeSession.duration))")))
            menu.addItem(disabledMenuItem(text.label(text.localizedStatus("Assertions"), text.assertionSummary(activeSession.assertionSummary))))
            menu.addItem(disabledMenuItem(text.label(text.localizedStatus("Reason"), activeSession.reason)))
            menu.addItem(disabledMenuItem(text.label(text.localizedStatus("Safety"), text.localizedSafetyNotes(safetyNotes(for: activeSession)))))
            menu.addItem(menuItem(text.stop, action: #selector(stopSessionFromMenu)))
        } else {
            if let lastErrorMessage {
                menu.addItem(disabledMenuItem(text.label(text.localizedStatus("Last error"), lastErrorMessage)))
                menu.addItem(.separator())
            }
            menu.addItem(menuItem(text.choose(en: "Start Indefinitely", zh: "开始无限期"), action: #selector(startIndefinitely)))
            menu.addItem(menuItem(text.choose(en: "Start 30 Minutes", zh: "开始 30 分钟"), action: #selector(startThirtyMinutes)))
            menu.addItem(menuItem(text.choose(en: "Start 1 Hour", zh: "开始 1 小时"), action: #selector(startOneHour)))
            menu.addItem(menuItem(text.choose(en: "Start 4 Hours", zh: "开始 4 小时"), action: #selector(startFourHours)))
        }
        menu.addItem(.separator())
        let displayItem = menuItem(text.keepDisplayAwake, action: #selector(toggleDisplayAwake))
        displayItem.state = keepDisplayAwake ? .on : .off
        menu.addItem(displayItem)
        let batteryItem = menuItem(text.allowBatteryLongSessions, action: #selector(toggleBatteryPolicy))
        batteryItem.state = allowLongSessionsOnBattery ? .on : .off
        menu.addItem(batteryItem)
        menu.addItem(disabledMenuItem(text.localizedStatus(agentActivitySummary)))
        menu.addItem(disabledMenuItem(text.lidLimitMenu))
        let notificationsItem = menuItem(text.enableNotifications, action: #selector(toggleNotifications))
        notificationsItem.state = notificationsEnabled ? .on : .off
        menu.addItem(notificationsItem)
        menu.addItem(menuItem(text.choose(en: "Menu Bar Mode: \(text.menuBarModeLabel(settings.menuBarDisplayMode))", zh: "菜单栏模式：\(text.menuBarModeLabel(settings.menuBarDisplayMode))"), action: #selector(cycleMenuBarMode)))
        menu.addItem(languageMenuItem())
        let launchWindowItem = menuItem(text.choose(en: "Show Window on Launch", zh: "启动时显示窗口"), action: #selector(toggleOpenWindowOnLaunch))
        launchWindowItem.state = settings.openControlWindowOnLaunch ? .on : .off
        menu.addItem(launchWindowItem)
        menu.addItem(disabledMenuItem(historyMenuSummary()))
        menu.addItem(menuItem(text.clearHistory, action: #selector(clearHistory)))
        menu.addItem(.separator())
        menu.addItem(menuItem(text.choose(en: "Show Caff", zh: "显示 Caff"), action: #selector(showControlWindow)))
        menu.addItem(menuItem(text.choose(en: "Quit Caff", zh: "退出 Caff"), action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
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
            return "CAFF \(text.sourceLabel(activeSession.source))"
        }
    }

    private func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func languageMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: text.label(text.languageLabel, text.languageModeLabel(settings.languageMode)),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()
        for mode in AppLanguageMode.allCases {
            let modeItem = menuItem(text.languageModeLabel(mode), action: #selector(changeLanguageModeFromMenu))
            modeItem.representedObject = mode.rawValue
            modeItem.state = mode == settings.languageMode ? .on : .off
            submenu.addItem(modeItem)
        }
        item.submenu = submenu
        return item
    }

    private func menuItem(_ title: String, action: Selector?, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }
}
