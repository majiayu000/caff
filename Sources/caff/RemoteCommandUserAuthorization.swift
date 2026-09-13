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
/// Lease payloads are HMAC-bound to the install token so a peer cannot forge a
/// lease for a Caff-minted secret. Peers who plant both token and lease can still
/// produce a valid MAC — bootstrap therefore remints on lease presence rather than
/// adopting the possibly attacker-known secret.
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

    private static let leasePayloadPrefix = "v1:"

    /// Scopes whose HMAC-valid leases were observed this process. Used so a remint
    /// rebinds only the originating scope (agent-touch must not promote to signing).
    private static let validatedScopeLock = NSLock()
    private static var validatedProvisioningScopes: Set<Scope> = []
    /// Absolute expiries of leases validated this process. Remint rebinds must reuse
    /// these timestamps — never grant a fresh 12h/30d window without LocalAuthentication.
    private static var validatedLeaseExpiries: [Scope: TimeInterval] = [:]

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
            // Remember which scope authorized this process so a remint during sign()
            // can rebind the same lease (agent-touch must not promote to signing).
            let expiry = try validatedLeaseExpiry(for: scope, now: now)
            noteValidatedProvisioningScope(scope, expiry: expiry)
            return
        }
        try authenticateUser(reason: reason)
        RemoteCommandAuth.noteRecentUserPresence()
        noteValidatedProvisioningScope(scope)
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
        RemoteCommandAuth.noteRecentUserPresence()
        noteValidatedProvisioningScope(scope)
        try writeLease(scope: scope, expiresAt: now.addingTimeInterval(leaseSeconds).timeIntervalSince1970)
    }

    /// Always prompts for user presence and never consults a signing lease.
    /// Notes presence so a subsequent remint/provision can record a fresh lease
    /// the receiver can validate without treating plantable leases as provenance.
    /// Used when revealing URL tickets — a prior lease must not mint tickets.
    static func requireFreshAuthorization(
        reason: String
    ) throws {
        try authenticateUser(reason: reason)
        RemoteCommandAuth.noteRecentUserPresence()
        // Tickets authorize general remote control; rebind the signing scope.
        noteValidatedProvisioningScope(.signing)
    }

    /// Registers LocalAuthentication as the gate when Caff must rotate a pre-existing
    /// (possibly peer-planted) slot claim during Keychain bootstrap. Plantable
    /// Keychain markers are never treated as live provenance on their own.
    static func installSlotClaimAttestationHandler() {
        RemoteCommandAuth.slotClaimAttestationHandler = {
            try requireFreshAuthorization(
                reason: "Authorize Caff to establish remote-control credentials"
            )
        }
    }

    /// If an HMAC-valid signing lease is present, note its token so Keychain bootstrap
    /// can remint across fresh CLI/app processes without re-prompting LocalAuthentication.
    /// Lease validity never authorizes adopting a preplanted secret.
    static func noteValidLeasesIfPresent(now: Date = Date()) {
        do {
            // Probe concrete accounts (not hasValidLease) so agent-touch is not
            // collapsed into signing via the agent-touch→signing superset rule.
            let timestamp = now.timeIntervalSince1970
            if let expiresAt = try readLeaseExpiresAt(scope: .signing), expiresAt > timestamp {
                noteValidatedProvisioningScope(.signing, expiry: expiresAt)
            }
            if let expiresAt = try readLeaseExpiresAt(scope: .agentTouch), expiresAt > timestamp {
                noteValidatedProvisioningScope(.agentTouch, expiry: expiresAt)
            }
        } catch {
            // Best-effort: token load will fall back to attestation/remint.
        }
    }

    /// After provisioning that consumed user presence, rebind every lease scope that
    /// was independently validated this process so a shared remint does not drop the
    /// longer agent-touch authorization when a signing lease was also present.
    static func recordProvisioningLeaseIfNeeded(
        leaseSeconds: TimeInterval? = nil,
        now: Date = Date()
    ) {
        guard RemoteCommandAuth.hasRecentUserPresence(consume: true) else { return }
        let scopes = takeAllValidatedProvisioningScopes()
        for (scope, preservedExpiry) in scopes {
            let seconds = leaseSeconds ?? (scope == .agentTouch ? hookLeaseSeconds : defaultLeaseSeconds)
            do {
                if try hasExactValidLease(scope: scope, now: now) {
                    continue
                }
                // Presence was just proven for remint; keep it noted through writeLease's
                // loadOrCreateToken so we do not re-enter attestation.
                RemoteCommandAuth.noteRecentUserPresence()
                // Rebind to the original absolute expiry when a validated lease authorized
                // this remint. A fresh full-duration window would let frequent hooks renew
                // agent-touch authorization indefinitely without LocalAuthentication.
                let expiresAt = preservedExpiry ?? now.addingTimeInterval(seconds).timeIntervalSince1970
                try writeLease(scope: scope, expiresAt: expiresAt)
            } catch {
                // Best-effort — next launch may re-attest.
            }
        }
    }

    /// Deletes the Keychain lease for `scope` (best-effort for missing items).
    static func revokeLease(scope: Scope) throws {
        try deleteKeychainItem(account: scope.rawValue, context: "lease revoke")
    }

    /// True when any HMAC-valid lease is present (signing or agent-touch).
    /// Used for quiet deferred receiver registration — never prompts.
    static func hasAnyValidLease(now: Date = Date()) -> Bool {
        let timestamp = now.timeIntervalSince1970
        if let expiresAt = try? readLeaseExpiresAt(scope: .signing), expiresAt > timestamp {
            return true
        }
        if let expiresAt = try? readLeaseExpiresAt(scope: .agentTouch), expiresAt > timestamp {
            return true
        }
        return false
    }

    private static func noteValidatedProvisioningScope(_ scope: Scope, expiry: TimeInterval? = nil) {
        validatedScopeLock.lock()
        validatedProvisioningScopes.insert(scope)
        if let expiry {
            validatedLeaseExpiries[scope] = expiry
        } else {
            // Fresh LocalAuthentication — do not reuse a previously observed expiry.
            validatedLeaseExpiries.removeValue(forKey: scope)
        }
        validatedScopeLock.unlock()
    }

    /// Absolute expiry of the lease that currently satisfies `scope`, if any.
    private static func validatedLeaseExpiry(for scope: Scope, now: Date) throws -> TimeInterval? {
        let timestamp = now.timeIntervalSince1970
        switch scope {
        case .signing:
            if let expiresAt = try readLeaseExpiresAt(scope: .signing), expiresAt > timestamp {
                return expiresAt
            }
            return nil
        case .agentTouch:
            if let expiresAt = try readLeaseExpiresAt(scope: .agentTouch), expiresAt > timestamp {
                return expiresAt
            }
            if let expiresAt = try readLeaseExpiresAt(scope: .signing), expiresAt > timestamp {
                return expiresAt
            }
            return nil
        }
    }

    /// Returns every scope noted this process (with preserved expiry) so remint can
    /// rebind signing and agent-touch independently. Defaults to signing when
    /// presence was proven without a prior lease probe.
    private static func takeAllValidatedProvisioningScopes() -> [(Scope, TimeInterval?)] {
        validatedScopeLock.lock()
        let scopes = validatedProvisioningScopes
        validatedProvisioningScopes.removeAll()
        var result: [(Scope, TimeInterval?)] = []
        for scope in [Scope.signing, Scope.agentTouch] where scopes.contains(scope) {
            result.append((scope, validatedLeaseExpiries.removeValue(forKey: scope)))
        }
        // Drop any leftover expiry entries that were not paired with a scope note.
        validatedLeaseExpiries.removeAll()
        validatedScopeLock.unlock()
        if result.isEmpty {
            return [(.signing, nil)]
        }
        return result
    }

    private static func hasExactValidLease(scope: Scope, now: Date) throws -> Bool {
        let timestamp = now.timeIntervalSince1970
        guard let expiresAt = try readLeaseExpiresAt(scope: scope), expiresAt > timestamp else {
            return false
        }
        return true
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
            // Unattended ACL recovery must not block on Keychain authorization UI.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
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
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw Error.storageFailed("lease keychain item is not UTF-8")
        }

        // Reject preplanted plain timestamps and any payload we cannot authenticate
        // against the install token (boundary peers cannot forge without the secret).
        guard let expiresAt = try verifiedLeaseExpiry(rawPayload: raw, scope: scope) else {
            // Only delete if the Keychain value is still the rejected snapshot so a
            // concurrent rebind to a valid lease is not wiped.
            try deleteKeychainItemIfValueMatches(
                account: scope.rawValue,
                expected: raw,
                context: "preplant lease remove"
            )
            return nil
        }
        return expiresAt
    }

    private static func verifiedLeaseExpiry(rawPayload: String, scope: Scope) throws -> TimeInterval? {
        // Expected: v1:<expirySeconds>:<hmacHex>
        guard rawPayload.hasPrefix(leasePayloadPrefix) else {
            return nil
        }
        let body = String(rawPayload.dropFirst(leasePayloadPrefix.count))
        guard let split = body.firstIndex(of: ":") else {
            return nil
        }
        let expiryRaw = String(body[..<split])
        let mac = String(body[body.index(after: split)...])
        // Parse as Int directly — Double(Int.max) rounds to 2^63, so a range check
        // against Double(Int.max) would accept a non-Int-representable expiry and
        // trap on Int(expiresAt) before the MAC can be rejected.
        guard let expirySeconds = Int(expiryRaw), !mac.isEmpty else {
            return nil
        }
        let expiresAt = TimeInterval(expirySeconds)

        guard let token = try RemoteCommandAuth().peekProvisionedKeychainToken() else {
            return nil
        }
        let expected = leaseMAC(token: token, scope: scope, expiresAt: expirySeconds)
        guard RemoteCommandAuth.constantTimeEqualsPublic(mac, expected) else {
            return nil
        }
        RemoteCommandAuth.noteLeaseValidatedToken(token)
        return expiresAt
    }

    private static func writeLease(scope: Scope, expiresAt: TimeInterval) throws {
        let token = try RemoteCommandAuth().loadOrCreateToken()
        // Reject values that are not exactly Int-representable. Double(Int.max) rounds
        // up to 2^63, so use an exclusive upper bound rather than <= Double(Int.max).
        guard expiresAt.isFinite,
              expiresAt >= Double(Int.min),
              expiresAt < Double(Int.max)
        else {
            throw Error.storageFailed("lease expiry is not a finite Int-representable timestamp")
        }
        let expirySeconds = Int(expiresAt)
        let mac = leaseMAC(token: token, scope: scope, expiresAt: expirySeconds)
        let payload = "\(leasePayloadPrefix)\(expirySeconds):\(mac)"
        guard let data = payload.data(using: .utf8) else {
            throw Error.storageFailed("lease payload is not UTF-8")
        }

        // Never SecItemUpdate in place: a peer-precreated item keeps its ACL across
        // update. Delete any pre-existing account then recreate with our executable ACL.
        try deleteKeychainItem(account: scope.rawValue, context: "lease replace before write")

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
            // Race: peer recreated between delete and add — remove again and retry once.
            try deleteKeychainItem(account: scope.rawValue, context: "lease duplicate replace")
            status = SecItemAdd(addQuery as CFDictionary, nil)
            if status == errSecParam {
                addQuery.removeValue(forKey: kSecAttrAccessible as String)
                status = SecItemAdd(addQuery as CFDictionary, nil)
            }
        }
        guard status == errSecSuccess else {
            throw Error.storageFailed("lease keychain write failed (\(status))")
        }
    }

    private static func leaseMAC(token: String, scope: Scope, expiresAt: Int) -> String {
        RemoteCommandAuth.hmacHex(
            key: token,
            message: "lease:v1:\(scope.rawValue):\(expiresAt)"
        )
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

    private static func deleteKeychainItemIfValueMatches(
        account: String,
        expected: String,
        context: String
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: RemoteCommandAuth.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return
        }
        if status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            try deleteKeychainItem(account: account, context: context)
            return
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return
        }
        guard RemoteCommandAuth.constantTimeEqualsPublic(raw, expected) else {
            // Concurrent writer replaced the rejected snapshot with a new value.
            return
        }
        try deleteKeychainItem(account: account, context: context)
    }
}
