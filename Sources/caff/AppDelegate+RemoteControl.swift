import AppKit
import Carbon.HIToolbox
import CaffCore
import Darwin

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
        do {
            remoteCommandServer = try RemoteCommandServer { [weak self] userInfo in
                self?.acceptSignedRemoteCommand(userInfo) ?? false
            }
        } catch {
            fputs("Caff remote command channel is unavailable: \(error)\n", stderr)
        }
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        fputs("Caff ignored a caff:// command. Use the Caff executable.\n", stderr)
    }

    func acceptSignedRemoteCommand(_ userInfo: [String: String]) -> Bool {
        var accepted = false
        withRemoteErrorPresentation {
            do {
                try applyRemoteCommand(userInfo: userInfo)
                accepted = true
            } catch {
                showError(error)
            }
        }
        return accepted
    }

    private func applyRemoteCommand(userInfo: [String: String]) throws {
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
}
