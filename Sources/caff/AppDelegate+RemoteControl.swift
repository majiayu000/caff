import AppKit
import Carbon.HIToolbox
import CaffCore

private enum RemoteCommandApplyError: Error, CustomStringConvertible {
    case invalidURL(String)
    case unknownAction(String)
    case sessionAlreadyRunning(String)

    var description: String {
        switch self {
        case let .invalidURL(value):
            return "Invalid Caff URL: \(value)"
        case let .unknownAction(value):
            return "Unknown remote action: \(value)"
        case let .sessionAlreadyRunning(reason):
            return "A wake session is already running: \(reason)"
        }
    }
}

extension AppDelegate {
    func registerRemoteControlHandlers() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleRemoteCommandNotification(_:)),
            name: RemoteCommandBridge.notificationName,
            object: RemoteCommandBridge.bundleIdentifier
        )
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc func handleRemoteCommandNotification(_ notification: Notification) {
        let userInfo = (notification.userInfo as? [String: String]) ?? [:]
        do {
            try applyRemoteCommand(userInfo: userInfo)
        } catch {
            showError(error)
        }
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString),
              var userInfo = userInfo(from: url) else {
            showError(RemoteCommandApplyError.invalidURL(event.description))
            return
        }
        if userInfo[RemoteCommandBridge.Key.action] == "start",
           userInfo[RemoteCommandBridge.Key.source] == nil {
            userInfo[RemoteCommandBridge.Key.source] = SessionSource.url.rawValue
        }
        do {
            try applyRemoteCommand(userInfo: userInfo)
        } catch {
            showError(error)
        }
    }

    private func applyRemoteCommand(userInfo: [String: String]) throws {
        let action = userInfo[RemoteCommandBridge.Key.action] ?? ""
        switch action {
        case "start":
            try startRemoteSession(userInfo: userInfo)
        case "stop":
            stopSession(result: .stopped)
        default:
            throw RemoteCommandApplyError.unknownAction(action)
        }
    }

    private func startRemoteSession(userInfo: [String: String]) throws {
        guard activeSession == nil else {
            throw RemoteCommandApplyError.sessionAlreadyRunning(activeSession?.reason ?? "Caff session")
        }
        let duration = try RemoteControlParser.duration(minutes: userInfo[RemoteCommandBridge.Key.minutes])
        let source = try RemoteControlParser.source(userInfo[RemoteCommandBridge.Key.source])
        keepDisplayAwake = RemoteControlParser.bool(userInfo[RemoteCommandBridge.Key.displayAwake])
        let reason = userInfo[RemoteCommandBridge.Key.reason] ?? "Caff remote start"
        _ = startSession(duration: duration, source: source, reason: reason)
    }

    private func userInfo(from url: URL) -> [String: String]? {
        guard url.scheme == "caff" else {
            return nil
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let action = url.host?.isEmpty == false ? url.host! : url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !action.isEmpty else {
            return nil
        }
        var userInfo = [RemoteCommandBridge.Key.action: action]
        for item in components.queryItems ?? [] {
            userInfo[item.name] = item.value ?? ""
        }
        return userInfo
    }
}
