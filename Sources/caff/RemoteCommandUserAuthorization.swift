import CaffCore
import Foundation
import LocalAuthentication
import Security

/// Gates trusted-CLI signing so same-UID peers cannot treat the Caff executable as a
/// silent signing oracle for start/stop/agent-touch.
///
/// A short-lived Keychain lease (same executable ACL as the install token) records that
/// the user already completed LocalAuthentication. Creating or refreshing that lease
/// always requires user presence; merely launching Caff is not enough.
///
/// Leases are scoped: the long-lived install-hooks lease authorizes `agent-touch` only.
/// `start` / `stop` require a general signing lease (or a fresh prompt).
enum RemoteCommandUserAuthorization {
    enum Scope: String {
        /// start / stop / authorize-remote / general CLI signing.
        case signing = "cli-signing-lease"
        /// install-hooks / agent-touch only — must not satisfy start/stop.
        case agentTouch = "cli-agent-touch-lease"
    }

    static let defaultLeaseSeconds: TimeInterval = 12 * 60 * 60
    /// Install-hooks is an explicit user action; grant a longer unattended window for agent-touch.
    static let hookLeaseSeconds: TimeInterval = 30 * 24 * 60 * 60

    enum Error: Swift.Error, CustomStringConvertible {
        case denied
        case unavailable(String)
        case storageFailed(String)

        var description: String {
            switch self {
            case .denied:
                return "Remote command authorization denied"
            case let .unavailable(message):
                return "Remote command authorization unavailable: \(message)"
            case let .storageFailed(message):
                return "Remote command authorization storage failed: \(message)"
            }
        }
    }

    /// Ensures a valid signing lease exists for `scope`, prompting for user presence when needed.
    ///
    /// - `signing` accepts only the general signing lease.
    /// - `agentTouch` accepts the agent-touch lease or the general signing lease (superset).
    static func ensureAuthorized(
        scope: Scope = .signing,
        reason: String = "Authorize Caff to sign a local remote-control command",
        leaseSeconds: TimeInterval = defaultLeaseSeconds,
        now: Date = Date()
    ) throws {
        if try hasValidLease(for: scope, now: now) {
            return
        }
        try authenticateUser(reason: reason)
        try writeLease(scope: scope, expiresAt: now.addingTimeInterval(leaseSeconds).timeIntervalSince1970)
    }

    /// Always prompts, then writes a fresh lease for `scope`.
    /// Used by `authorize-remote` and install-hooks.
    static func authorize(
        scope: Scope = .signing,
        reason: String,
        leaseSeconds: TimeInterval = defaultLeaseSeconds,
        now: Date = Date()
    ) throws {
        try authenticateUser(reason: reason)
        try writeLease(scope: scope, expiresAt: now.addingTimeInterval(leaseSeconds).timeIntervalSince1970)
    }

    /// Always prompts for user presence and never consults or refreshes a signing lease.
    /// Used when revealing the reusable install token — a lease must not become permanent
    /// credential disclosure.
    static func requireFreshAuthorization(
        reason: String
    ) throws {
        try authenticateUser(reason: reason)
    }

    private static func hasValidLease(for scope: Scope, now: Date) throws -> Bool {
        let timestamp = now.timeIntervalSince1970
        switch scope {
        case .signing:
            if let expiresAt = try readLeaseExpiresAt(scope: .signing), expiresAt > timestamp {
                return true
            }
            return false
        case .agentTouch:
            if let expiresAt = try readLeaseExpiresAt(scope: .agentTouch), expiresAt > timestamp {
                return true
            }
            // A general signing authorization also covers agent-touch.
            if let expiresAt = try readLeaseExpiresAt(scope: .signing), expiresAt > timestamp {
                return true
            }
            return false
        }
    }

    private static func authenticateUser(reason: String) throws {
        let context = LAContext()
        context.localizedCancelTitle = "Deny"
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            let message = authError?.localizedDescription ?? "device owner authentication is unavailable"
            throw Error.unavailable(message)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        var evaluateError: Swift.Error?
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            success = ok
            evaluateError = error
            semaphore.signal()
        }
        semaphore.wait()
        guard success else {
            if let evaluateError {
                throw Error.unavailable(evaluateError.localizedDescription)
            }
            throw Error.denied
        }
    }

    private static func readLeaseExpiresAt(scope: Scope) throws -> TimeInterval? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: RemoteCommandAuth.keychainService,
            kSecAttrAccount as String: scope.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        // After an ad-hoc upgrade the ACL may reject the new binary — treat as no lease.
        if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            try deleteKeychainItem(
                account: scope.rawValue,
                context: "lease rotate"
            )
            return nil
        }
        guard status == errSecSuccess else {
            throw Error.storageFailed("lease keychain read failed (\(status))")
        }
        guard
            let data = item as? Data,
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let expiresAt = TimeInterval(raw)
        else {
            throw Error.storageFailed("lease keychain item is not a timestamp")
        }
        return expiresAt
    }

    private static func writeLease(scope: Scope, expiresAt: TimeInterval) throws {
        guard let data = String(Int(expiresAt)).data(using: .utf8) else {
            throw Error.storageFailed("lease timestamp is not UTF-8")
        }

        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: RemoteCommandAuth.keychainService,
            kSecAttrAccount as String: scope.rawValue,
        ]
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            // Stale ACL from a previous ad-hoc binary — delete and recreate.
            if updateStatus == errSecAuthFailed || updateStatus == errSecInteractionNotAllowed {
                try deleteKeychainItem(account: scope.rawValue, context: "lease update rotate")
            } else {
                throw Error.storageFailed("lease keychain update failed (\(updateStatus))")
            }
        }

        let access = try RemoteCommandAuth.makeExecutableScopedAccess(
            descriptor: "Caff remote CLI signing lease"
        )
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: RemoteCommandAuth.keychainService,
            kSecAttrAccount as String: scope.rawValue,
            kSecAttrLabel as String: "Caff remote CLI signing lease (\(scope.rawValue))",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccess as String: access,
            kSecValueData as String: data,
        ]
        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecParam {
            addQuery.removeValue(forKey: kSecAttrAccessible as String)
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        if status == errSecDuplicateItem {
            let retry = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
            guard retry == errSecSuccess else {
                throw Error.storageFailed("lease keychain duplicate-update failed (\(retry))")
            }
            return
        }
        guard status == errSecSuccess else {
            throw Error.storageFailed("lease keychain write failed (\(status))")
        }
    }

    private static func deleteKeychainItem(account: String, context: String) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: RemoteCommandAuth.keychainService,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error.storageFailed("\(context) delete failed (\(status))")
        }
    }
}
