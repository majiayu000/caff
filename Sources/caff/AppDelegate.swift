import AppKit
import CaffCore

private struct ActiveSession {
    let duration: SessionDuration
    let endDate: Date?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let powerAssertions = PowerAssertionController()
    private let windowStatusLabel = NSTextField(labelWithString: "Off")
    private let displayAwakeCheckbox = NSButton(checkboxWithTitle: "Keep display awake", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private var startButtons: [NSButton] = []
    private var controlWindow: NSWindow?
    private var activeSession: ActiveSession?
    private var updateTimer: Timer?
    private var keepDisplayAwake = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "CAFF"
        rebuildMenu()
        updateStatusTitle()
        showControlWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        try? powerAssertions.stop()
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
                try powerAssertions.start(options: options(for: activeSession.duration))
            } catch {
                keepDisplayAwake.toggle()
                clearSessionState()
                showError(error)
            }
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

        if let endDate = activeSession.endDate, Date() >= endDate {
            stopSession()
            return
        }

        updateStatusTitle()
    }

    private func startSession(duration: SessionDuration) {
        let startedAt = Date()

        do {
            try powerAssertions.start(options: options(for: duration))
            activeSession = ActiveSession(
                duration: duration,
                endDate: duration.endDate(from: startedAt)
            )
            scheduleTimer()
            rebuildMenu()
            updateStatusTitle()
        } catch {
            showError(error)
        }
    }

    private func stopSession() {
        do {
            try powerAssertions.stop()
            clearSessionState()
            rebuildMenu()
            updateStatusTitle()
        } catch {
            showError(error)
        }
    }

    private func options(for duration: SessionDuration) -> SessionOptions {
        SessionOptions(duration: duration, keepDisplayAwake: keepDisplayAwake)
    }

    private func scheduleTimer() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(
            timeInterval: 1,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(updateTimer!, forMode: .common)
    }

    private func clearSessionState() {
        activeSession = nil
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func updateStatusTitle() {
        guard let activeSession else {
            statusItem.button?.title = "CAFF"
            updateControlWindow()
            return
        }

        let remaining = RemainingTimeFormatter.compactRemaining(until: activeSession.endDate)
        statusItem.button?.title = "CAFF \(remaining)"
        updateControlWindow()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if let activeSession {
            let status = NSMenuItem(title: "Running: \(activeSession.duration.label)", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(menuItem("Stop", action: #selector(stopSessionFromMenu)))
        } else {
            menu.addItem(menuItem("Start Indefinitely", action: #selector(startIndefinitely)))
            menu.addItem(menuItem("Start 30 Minutes", action: #selector(startThirtyMinutes)))
            menu.addItem(menuItem("Start 1 Hour", action: #selector(startOneHour)))
            menu.addItem(menuItem("Start 4 Hours", action: #selector(startFourHours)))
        }

        menu.addItem(.separator())

        let displayItem = menuItem("Keep Display Awake", action: #selector(toggleDisplayAwake))
        displayItem.state = keepDisplayAwake ? .on : .off
        menu.addItem(displayItem)

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
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
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

        stopButton.target = self
        stopButton.action = #selector(stopSessionFromMenu)
        stopButton.bezelStyle = .rounded

        let stack = NSStackView(views: [
            titleLabel,
            windowStatusLabel,
            startGrid,
            displayAwakeCheckbox,
            stopButton
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(stack)
        window.contentView = contentView

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            startGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
            let remaining = RemainingTimeFormatter.compactRemaining(until: activeSession.endDate)
            statusText = activeSession.endDate == nil ? "On" : "On: \(remaining)"
        } else {
            statusText = "Off"
        }

        windowStatusLabel.stringValue = statusText
        displayAwakeCheckbox.state = keepDisplayAwake ? .on : .off
        stopButton.isEnabled = isRunning
        for button in startButtons {
            button.isEnabled = !isRunning
        }
    }

    private func menuItem(_ title: String, action: Selector?, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Caff could not update the wake session"
        alert.informativeText = String(describing: error)
        alert.runModal()
    }
}
