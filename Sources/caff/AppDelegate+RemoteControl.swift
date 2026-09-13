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
        // Provision the install token at launch. External caff:// callers obtain a
        // short-lived URL ticket via `caff remote-token` (user-authorized), not the
        // durable Keychain secret (custom schemes are not exclusive).
        do {
            _ = try RemoteCommandAuth().loadOrCreateToken()
        } catch {
            fputs("Caff failed to provision remote command token: \(error)\n", stderr)
        }
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
        withRemoteErrorPresentation {
            do {
                try applyRemoteCommand(userInfo: userInfo)
            } catch RemoteCommandAuthError.missingToken, RemoteCommandAuthError.invalidToken {
                // Reject forged/missing-token IPC without modal spam.
                fputs("Caff rejected unauthenticated remote command notification\n", stderr)
            } catch {
                showError(error)
            }
        }
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        withRemoteErrorPresentation {
            do {
                guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
                      let url = URL(string: urlString),
                      var userInfo = userInfo(from: url) else {
                    throw RemoteCommandApplyError.invalidURL(event.description)
                }
                if userInfo[RemoteCommandBridge.Key.action] == "start",
                   userInfo[RemoteCommandBridge.Key.source] == nil {
                    userInfo[RemoteCommandBridge.Key.source] = SessionSource.url.rawValue
                }
                try applyRemoteCommand(userInfo: userInfo)
            } catch RemoteCommandAuthError.missingToken, RemoteCommandAuthError.invalidToken {
                fputs("Caff rejected unauthenticated caff:// remote command\n", stderr)
            } catch {
                showError(error)
            }
        }
    }

    private func applyRemoteCommand(userInfo: [String: String]) throws {
        try RemoteCommandAuth().authenticate(userInfo)
        let action = userInfo[RemoteCommandBridge.Key.action] ?? ""
        switch action {
        case "start":
            try startRemoteSession(userInfo: userInfo)
        case "stop":
            cancelAgentActivityCooldown()
            stopSession(result: .stopped)
        case "agent-touch":
            try touchRemoteAgentActivity(userInfo: userInfo)
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
        let reason = userInfo[RemoteCommandBridge.Key.reason] ?? text.choose(en: "Caff remote start", zh: "Caff 远程启动")
        _ = startSession(duration: duration, source: source, reason: reason)
    }

    private func touchRemoteAgentActivity(userInfo: [String: String]) throws {
        let source = userInfo[RemoteCommandBridge.Key.agentSource] ?? userInfo[RemoteCommandBridge.Key.source]
        let cooldownSeconds = try RemoteControlParser.cooldownSeconds(
            userInfo[RemoteCommandBridge.Key.cooldownSeconds]
        )
        touchAgentActivity(source: source, cooldownSeconds: cooldownSeconds)
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
