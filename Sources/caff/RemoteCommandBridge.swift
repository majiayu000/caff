import Foundation

enum RemoteCommandBridge {
    static let bundleIdentifier = "com.starlight.caff"

    enum Key {
        static let action = "action"
        static let minutes = "minutes"
        static let reason = "reason"
        static let displayAwake = "displayAwake"
        static let source = "source"
        static let agentSource = "agentSource"
        static let cooldownSeconds = "cooldownSeconds"
    }

    static func post(_ userInfo: [String: String]) throws {
        try RemoteCommandClient.send(userInfo)
    }
}
