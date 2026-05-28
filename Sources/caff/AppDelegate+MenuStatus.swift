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
        menu.addItem(disabledMenuItem(agentActivitySummary))
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
}
